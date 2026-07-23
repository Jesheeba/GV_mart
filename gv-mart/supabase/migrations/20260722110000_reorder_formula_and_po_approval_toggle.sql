-- Build Order Guardrails — "Build-ready alongside" items C1 + C2 (Meeting
-- spec Section C). Both are independent of the assignment-engine work.
--
-- C1: reorder formula was a fixed `reorder_qty` regardless of how far below
-- min_stock the trigger fired — a huge one-transaction drop and a
-- just-crossed-the-line drop ordered the exact same quantity. New formula:
-- order qty = max_stock − current stock (owner's own example: max 100,
-- min 10, hits 10 → order 90). `max_stock` is new, nullable, backfilled to
-- `min_stock + reorder_qty` for every existing row so the formula produces
-- EXACTLY today's order quantity for anything nobody has re-tuned yet — no
-- silent behavior change for items the owner hasn't touched. `reorder_qty`
-- is kept (not dropped) purely as that fallback's other half; it's no
-- longer the live ordered quantity once max_stock is set.
--
-- Seasonal stock levels (also named in C1) are NOT built here — "seasonal"
-- has no defined shape yet (calendar months? owner-defined date ranges?
-- per-item or per-category?) and guessing the data model wrong is expensive
-- to undo per this project's own working rule. Flagging for a follow-up
-- decision rather than building a guess.
--
-- C2: `po_approval_threshold` already existed but only ever flagged a PO
-- for review AFTER it had already auto-sent — never actually gated sending.
-- New `settings.po_requires_approval` is the real on/off switch the meeting
-- spec asks for: OFF (default) = exactly today's behavior (send immediately,
-- threshold-based post-hoc flag as before); ON = every auto-drafted PO is
-- created as `status='draft'` (no WhatsApp dispatch, no `sent_channel`) with
-- a mandatory pending approval, and the new `approve_purchase_order` RPC is
-- how master actually releases it — approving only flips the generic
-- `approvals` row today (see systemPages.ts's decideApproval doc comment:
-- "status-only, audit-trail action"), so without this dedicated RPC a
-- draft PO would never transition to sent even after being "approved".

alter table public.inventory
  add column if not exists max_stock integer;

update public.inventory
set max_stock = min_stock + reorder_qty
where max_stock is null;

alter table public.inventory
  add constraint inventory_max_stock_check check (max_stock is null or max_stock >= min_stock);

alter table public.settings
  add column if not exists po_requires_approval boolean not null default false;

-- Based on the truly-latest _auto_draft_purchase_order (20260715300000_operational_alerts.sql,
-- which itself is based on the purchase_order_items->po_items repoint in
-- 20260702170300_automation_purchase_functions_fix.sql) — preserves both
-- notification inserts from that migration, only changes the order-quantity
-- formula and adds the approval-gate branch.
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
  v_requires_approval boolean;
  v_already_open boolean;
  v_order_qty integer;
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

  -- C1: order up to max_stock (falling back to min_stock + reorder_qty for
  -- any row that predates max_stock) instead of always ordering a fixed qty.
  v_order_qty := greatest(1, coalesce(new.max_stock, new.min_stock + new.reorder_qty) - new.stock_qty);

  select po_approval_threshold, po_requires_approval into v_threshold, v_requires_approval
  from public.settings where org_id = new.org_id;
  v_total := coalesce(v_price, 0) * v_order_qty;

  if v_requires_approval then
    -- C2, ON: create the PO as a draft, do not dispatch it, require
    -- approval unconditionally (the toggle itself is the gate — independent
    -- of the amount threshold, which only applies in the OFF branch below).
    insert into public.purchase_orders (org_id, supplier_id, status, total)
    values (new.org_id, v_supplier_id, 'draft', v_total)
    returning id into v_po_id;

    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (new.org_id, v_po_id, new.item_type, new.item_id, v_order_qty, coalesce(v_price, 0));

    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select new.org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = new.org_id and role = 'master' limit 1;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'low_stock', 'Stock critical — PO awaiting approval',
      format('Stock for this %s is at %s (min %s). A draft purchase order for %s units needs approval before it sends.', new.item_type, new.stock_qty, new.min_stock, v_order_qty),
      new.id
    );

    return new;
  end if;

  -- C2, OFF: exactly today's behavior — send immediately, only the amount
  -- threshold (independent of the new toggle) flags it for after-the-fact review.
  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (new.org_id, v_supplier_id, 'sent', v_total, 'whatsapp')
  returning id into v_po_id;

  insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
  values (new.org_id, v_po_id, new.item_type, new.item_id, v_order_qty, coalesce(v_price, 0));

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  values (new.org_id, 'outbound', (select whatsapp from public.suppliers where id = v_supplier_id), 'po_sent', 'po.auto_sent',
          jsonb_build_object('po_id', v_po_id, 'total', v_total, 'item_type', new.item_type, 'item_id', new.item_id),
          'purchase_order', v_po_id, 'sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — PO auto-drafted',
    format('Stock for this %s is at %s (min %s). A purchase order for %s units was auto-drafted and sent.', new.item_type, new.stock_qty, new.min_stock, v_order_qty),
    new.id
  );

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select new.org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = new.org_id and role = 'master' limit 1;
  end if;

  return new;
end;
$$;

-- C2: the actual "release a draft PO once approved" step. decideApproval
-- (systemPages.ts) is a plain generic status-flip with no side effects, so
-- approving a PO-type approval needs this dedicated RPC to actually
-- transition the linked purchase_order and dispatch it — otherwise a draft
-- PO awaiting approval would stay a draft forever even once "approved".
-- Rejecting a PO needs no equivalent RPC: it simply never leaves 'draft',
-- which is already the correct, safe resting state (po_status has no
-- 'cancelled' value — draft-and-never-sent already means exactly that).
create or replace function public.approve_purchase_order(p_approval_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_approval approvals;
  v_po purchase_orders;
begin
  if not public.is_master() then
    raise exception 'approve_purchase_order: only master may approve a purchase order';
  end if;

  select * into v_approval from public.approvals where id = p_approval_id and org_id = public.current_org_id();
  if v_approval.id is null then
    raise exception 'approve_purchase_order: approval % not found', p_approval_id;
  end if;
  if v_approval.type is distinct from 'po' then
    raise exception 'approve_purchase_order: approval % is not a PO approval', p_approval_id;
  end if;
  if v_approval.status is distinct from 'pending' then
    raise exception 'approve_purchase_order: approval % is not pending', p_approval_id;
  end if;

  select * into v_po from public.purchase_orders where id = v_approval.ref_id and org_id = public.current_org_id();
  if v_po.id is null then
    raise exception 'approve_purchase_order: purchase order % not found', v_approval.ref_id;
  end if;
  if v_po.status is distinct from 'draft' then
    raise exception 'approve_purchase_order: purchase order % is not a pending draft', v_po.id;
  end if;

  -- Close the double-click/concurrent-approve race: the two SELECTs above are
  -- plain unlocked reads, so two overlapping calls (a double-click before the
  -- UI's isPending disables the button, or a client retry after a dropped
  -- response) could both pass the pending/draft checks before either commits.
  -- Make the actual state transitions themselves the real guard — each
  -- UPDATE only matches a row still in the expected state, so only the first
  -- of two concurrent callers ever flips it; the loser affects 0 rows and is
  -- caught below instead of re-dispatching the WhatsApp message and
  -- notification a second time.
  update public.approvals set status = 'approved', approver_id = auth.uid()
    where id = p_approval_id and status = 'pending'
    returning * into v_approval;
  if v_approval.id is null then
    raise exception 'approve_purchase_order: approval % was already decided by a concurrent request', p_approval_id;
  end if;

  update public.purchase_orders set status = 'sent', sent_channel = 'whatsapp'
    where id = v_po.id and status = 'draft'
    returning * into v_po;
  if v_po.id is null then
    raise exception 'approve_purchase_order: purchase order % was already sent by a concurrent request', v_approval.ref_id;
  end if;

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  select v_po.org_id, 'outbound', s.whatsapp, 'po_sent', 'po.approved_and_sent',
         jsonb_build_object('po_id', v_po.id, 'total', v_po.total), 'purchase_order', v_po.id, 'sent'
  from public.suppliers s where s.id = v_po.supplier_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    v_po.org_id, 'operation_admin', 'low_stock', 'Approved PO sent',
    format('Purchase order %s (₹%s) was approved and sent to the supplier.', v_po.id, v_po.total), v_po.id
  );
end;
$$;

grant execute on function public.approve_purchase_order(uuid) to authenticated;
