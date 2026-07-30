-- Removes the old fixed `reorder_qty` reorder logic entirely. Per
-- 20260722110000_reorder_formula_and_po_approval_toggle.sql, `max_stock` was
-- already added and the order-qty formula already PREFERRED
-- `max_stock - stock_qty` — but it still fell back to
-- `min_stock + reorder_qty` whenever `max_stock` was null, and that exact
-- fallback line was carried forward verbatim into the newest trigger
-- definition in 20260725120000_po_quotation_first_with_timeout_safeguard.sql.
-- `reorder_qty` was therefore still live, not dead. This migration removes
-- it completely: order qty is now ALWAYS `max_stock - stock_qty`, full stop.
--
-- `settings.default_reorder_qty` (a global "Inventory Defaults" field) is
-- also removed — grepped every insert into `inventory` across the codebase
-- and every RPC; nothing ever actually read this column, new rows always
-- just used inventory.reorder_qty's own column default. Pure dead config.
--
-- Does NOT touch: settings.po_requires_approval / po_approval_threshold
-- (approval gate, untouched), supplier_products selection, purchase_quote_
-- requests/replies, resolve_purchase_quote_requests, log_purchase_quote_
-- reply, approve_purchase_order — none of that logic changes, only how
-- v_order_qty is computed inside _auto_draft_purchase_order.

-- Defensive backfill: 20260722110000 already backfilled every row that
-- existed at the time, but any row inserted since then via the lazy
-- "insert into inventory (org_id, item_type, item_id, stock_qty)" pattern
-- (create_bill_entry, spare_handover, automation purchase functions) would
-- have gotten max_stock = null from the column default. Last chance to use
-- reorder_qty for this before the column is dropped below.
update public.inventory
set max_stock = min_stock + reorder_qty
where max_stock is null;

-- max_stock becomes the sole, required replenishment target. Default 20
-- matches today's effective default for untouched rows (min_stock 10 +
-- reorder_qty 10 = 20) — no silent behavior change for any item nobody has
-- re-tuned, same reasoning 20260722110000 used when max_stock was introduced.
alter table public.inventory
  alter column max_stock set default 20;

alter table public.inventory
  alter column max_stock set not null;

alter table public.inventory
  drop constraint inventory_max_stock_check;
alter table public.inventory
  add constraint inventory_max_stock_check check (max_stock >= min_stock);

alter table public.inventory
  drop column reorder_qty;

alter table public.settings
  drop column default_reorder_qty;

-- Same function body as 20260725120000's version — only the v_order_qty
-- line changes (no more coalesce/fallback to reorder_qty). Approval gate,
-- quote-request fan-out, already-open guard, and every notification are
-- byte-for-byte unchanged.
create or replace function public._auto_draft_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_qty integer;
  v_already_open boolean;
  v_has_supplier boolean;
  v_timeout_hours numeric(6, 2);
  v_request_id uuid;
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
  ) or exists (
    select 1 from public.purchase_quote_requests qr
    where qr.org_id = new.org_id and qr.status = 'open'
      and qr.item_type = new.item_type and qr.item_id = new.item_id
  ) into v_already_open;
  if v_already_open then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'low_stock', 'Stock critical (reorder already in progress)',
      format('Stock for this %s is at %s (min %s). A purchase order or open supplier quote request already covers it.', new.item_type, new.stock_qty, new.min_stock),
      new.id
    );
    return new;
  end if;

  select exists (
    select 1 from public.supplier_products
    where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id
  ) into v_has_supplier;
  if not v_has_supplier then
    return new;
  end if;

  -- Order qty always refills the shelf back up to max_stock — no fixed
  -- reorder quantity anywhere anymore.
  v_order_qty := greatest(1, new.max_stock - new.stock_qty);

  select po_quote_timeout_hours into v_timeout_hours from public.settings where org_id = new.org_id;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
  values (new.org_id, new.id, new.item_type, new.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
  returning id into v_request_id;

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  select new.org_id, 'outbound', s.whatsapp, 'po_quote_request', 'po.quote_request',
         jsonb_build_object('request_id', v_request_id, 'item_type', new.item_type, 'item_id', new.item_id, 'order_qty', v_order_qty),
         'purchase_quote_request', v_request_id, 'sent'
  from public.supplier_products sp
  join public.suppliers s on s.id = sp.supplier_id
  where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — quote requests sent',
    format('Stock for this %s is at %s (min %s). Quote requests were sent to all known suppliers for %s units; the lowest logged reply (or last-known-cheapest if nobody replies) will be ordered automatically after %s hours.', new.item_type, new.stock_qty, new.min_stock, v_order_qty, v_timeout_hours),
    new.id
  );

  return new;
end;
$$;
