-- Operational alerts: SLA breach, low stock, stuck spare handovers.
--
-- Gap: three real conditions (ticket SLA breached, stock crossed critical,
-- a spare handover sitting unsigned) had zero in-app signal — staff had to
-- proactively check each screen. This migration closes it two ways:
--
--   1. refresh_operational_alerts(p_org_id) — a "compute derived alert state
--      on page load" function, same pattern as refresh_amc_statuses
--      (20260702110100_service_amc_functions.sql line ~514): no pg_cron in
--      this environment, so there's no scheduler to fire this on a timer —
--      it's called from the frontend once per org on dashboard load instead
--      (src/app/admin/DashboardPage.tsx). Covers sla_breach and
--      handover_pending, both of which need a periodic *scan* (nothing else
--      writes to service_tickets/spare_handovers on the exact tick their SLA
--      lapses or their 24h pending window closes).
--
--   2. _auto_draft_purchase_order() — already a real event-driven trigger on
--      `inventory` (fires on the downward min_stock crossing). Extended to
--      also insert a notification, since low stock doesn't need a scan: the
--      trigger already fires at exactly the right moment.
--
-- Gate choice: refresh_operational_alerts is gated with is_staff() (master,
-- operation_admin, sales_admin), not is_ops_staff() (master,
-- operation_admin only) — even though the existing refresh_amc_statuses
-- template this mirrors actually uses is_ops_staff(). Deliberate deviation:
-- this is called unconditionally from DashboardPage.tsx, the landing page
-- for every staff role including sales_admin, and the function only ever
-- writes role='operation_admin' notifications regardless of who triggered
-- the scan — so there's no reason to block sales_admin's dashboard visit
-- from also running the scan; only operation_admin viewers will ever see
-- the resulting notifications (notifications.role is matched against the
-- *viewing* profile's own role in src/services/systemPages.ts).
--
-- notifications.type is a bare `text not null` column with no check
-- constraint (verified across every migration touching that table, same as
-- inventory_movements.reason) — 'sla_breach', 'low_stock', 'handover_pending'
-- need no constraint change to be accepted.

-- ── Scan: SLA-breached tickets + stuck-pending handovers ────────────────
-- Dedupe rule for both: insert at most ONE notification per (type, ref_id)
-- ever, regardless of whether that earlier notification was later read or
-- dismissed. This function has no scheduler and only runs on every
-- dashboard page-load, so "no *unread* one exists" would re-fire a fresh
-- notification each time staff mark the old one read but the ticket/handover
-- is still in the same bad state on the next visit — spamming the
-- notification list. Once a breach/stuck-handover has been surfaced at all,
-- the underlying record is presumably already known to ops staff (it's
-- either being worked or the handover is on someone's radar to chase), so
-- existence-regardless-of-read-status is the simplest correct dedupe key.
create or replace function public.refresh_operational_alerts(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'refresh_operational_alerts: only master, operation_admin, or sales_admin may run this';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'refresh_operational_alerts: org mismatch';
  end if;

  -- Open tickets whose SLA has already lapsed.
  insert into public.notifications (org_id, role, type, title, body, ref_id)
  select
    t.org_id, 'operation_admin', 'sla_breach', 'SLA breached',
    format('Ticket %s missed its SLA (was due %s).', t.id, to_char(t.sla_due_at, 'DD Mon HH24:MI')),
    t.id
  from public.service_tickets t
  where t.org_id = p_org_id
    and t.status not in ('completed', 'cancelled')
    and t.sla_due_at is not null
    and t.sla_due_at < now()
    and not exists (
      select 1 from public.notifications n
      where n.org_id = p_org_id and n.type = 'sla_breach' and n.ref_id = t.id
    );

  -- Spare handovers still 'pending' (unsigned/unconfirmed) 24h+ after creation.
  insert into public.notifications (org_id, role, type, title, body, ref_id)
  select
    h.org_id, 'operation_admin', 'handover_pending', 'Spare handover unsigned',
    format('Handover dated %s has been pending confirmation since %s.', h.date, to_char(h.created_at, 'DD Mon HH24:MI')),
    h.id
  from public.spare_handovers h
  where h.org_id = p_org_id
    and h.status = 'pending'
    and h.created_at < now() - interval '24 hours'
    and not exists (
      select 1 from public.notifications n
      where n.org_id = p_org_id and n.type = 'handover_pending' and n.ref_id = h.id
    );
end;
$$;

grant execute on function public.refresh_operational_alerts(uuid) to authenticated;

-- ── Low stock: notify on the same downward crossing the trigger already
-- guards against re-firing on ──────────────────────────────────────────────
-- Based on the truly-latest definition of _auto_draft_purchase_order —
-- 20260702170300_automation_purchase_functions_fix.sql (which repointed
-- purchase_order_items -> po_items; the 20260702170100 version is stale).
-- Body otherwise unchanged except for the two `insert into notifications`
-- calls added below: one in the "PO drafted" path, one in the "an open PO
-- already covers this item" early-return path — two different facts staff
-- need to know either way, so both get their own notification. No extra
-- dedupe logic needed beyond what the trigger already has: it only fires on
-- the downward min_stock crossing (guarded by the same `if` it always had),
-- so this is naturally already anti-spam.
create or replace function public._auto_draft_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_supplier_id uuid;
  v_price numeric(12, 2);
  v_po_id uuid;
  v_total numeric(12, 2);
  v_threshold numeric(12, 2);
  v_already_open boolean;
begin
  if new.stock_qty > new.min_stock or (old.stock_qty is not null and old.stock_qty <= old.min_stock) then
    return new;
  end if;

  select exists (
    select 1
    from public.po_items poi
    join public.purchase_orders po on po.id = poi.po_id
    where po.org_id = new.org_id and po.status in ('draft', 'sent')
      and poi.item_type = new.item_type and poi.item_id = new.item_id
  ) into v_already_open;
  if v_already_open then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'low_stock', 'Stock critical (PO already open)',
      format('Stock for this %s is at %s (min %s). An open purchase order already covers it.', new.item_type, new.stock_qty, new.min_stock),
      new.id
    );
    return new;
  end if;

  select supplier_id, price into v_supplier_id, v_price
  from public.supplier_products
  where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id
  order by is_preferred desc, price asc
  limit 1;

  if v_supplier_id is null then
    return new;
  end if;

  select po_approval_threshold into v_threshold from public.settings where org_id = new.org_id;
  v_total := coalesce(v_price, 0) * new.reorder_qty;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (new.org_id, v_supplier_id, 'sent', v_total, 'whatsapp')
  returning id into v_po_id;

  insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
  values (new.org_id, v_po_id, new.item_type, new.item_id, new.reorder_qty, coalesce(v_price, 0));

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  values (new.org_id, 'outbound', (select whatsapp from public.suppliers where id = v_supplier_id), 'po_sent', 'po.auto_sent',
          jsonb_build_object('po_id', v_po_id, 'total', v_total, 'item_type', new.item_type, 'item_id', new.item_id),
          'purchase_order', v_po_id, 'sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — PO auto-drafted',
    format('Stock for this %s is at %s (min %s). A purchase order for %s units was auto-drafted and sent.', new.item_type, new.stock_qty, new.min_stock, new.reorder_qty),
    new.id
  );

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select new.org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = new.org_id and role = 'master' limit 1;
  end if;

  return new;
end;
$$;

-- No `drop trigger` / `create trigger` needed: `inventory_auto_draft_po`
-- (20260702170100_automation_purchase_functions.sql line ~272) already binds
-- to this function by name; `create or replace function` above swaps the
-- body in place without touching the trigger definition.
