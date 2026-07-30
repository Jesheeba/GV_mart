-- Owner request 2026-07-29 (part 2 — see 20260729110000_gift_item_type.sql
-- for the enum change this depends on): gifts become real inventory rows,
-- auto-decrement when given, and reuse the existing max_stock reorder
-- trigger. Does NOT touch: gifts.threshold_amount / when a gift is offered
-- (untouched), or _sale_create_line_invoice's spare/product reorder_qty-
-- formula-adjacent blocking behavior (untouched, and deliberately not
-- mirrored — see below).

-- 1) Every existing gift (created before this migration) gets a tracked
-- inventory row now; every gift created from here on gets one the instant
-- it's inserted via the trigger below. Products/spares don't need an
-- equivalent backfill/trigger — they get their first inventory row lazily
-- on first PO/bill-entry/spare-handover — but gifts have no such receiving
-- flow, so this is the only way a gift ever becomes trackable stock.
-- min_stock/max_stock use the inventory table's own column defaults (10/20)
-- like any other freshly-created row.
insert into public.inventory (org_id, item_type, item_id, stock_qty)
select org_id, 'gift', id, 0
from public.gifts
on conflict (org_id, item_type, item_id, location) do nothing;

create or replace function public._gift_create_inventory_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.inventory (org_id, item_type, item_id, stock_qty)
  values (new.org_id, 'gift', new.id, 0)
  on conflict (org_id, item_type, item_id, location) do nothing;
  return new;
end;
$$;

create or replace trigger gifts_create_inventory_row
  after insert on public.gifts
  for each row execute function public._gift_create_inventory_row();

-- 2) A gift is logged to gift_logs from four call sites today: create_sale's
-- general above-threshold gift, create_sale's AMC-plan-included gift,
-- sell_amc_plan (admin standalone AMC sell), and queueSellAmcOnsite
-- (technician on-site AMC sell) — see 20260701090500_sales.sql,
-- 20260702100100_sales_phase5_functions.sql, 20260702110100_service_amc_
-- functions.sql, 20260724100000_technician_onsite_amc_sale.sql. Rather than
-- duplicate a decrement in all four, this single AFTER INSERT trigger on
-- gift_logs covers every one of them uniformly — any gift_logs row, however
-- it was written, means "a gift was physically handed over," which is
-- exactly when stock should drop by 1.
--
-- Deliberately NOT modeled on _sale_create_line_invoice's spare/product
-- decrement (which does `and stock_qty >= v_item.qty` then `raise
-- exception` when that fails, aborting the whole sale). Owner's explicit
-- decision: a gift is a bonus, never a blocker to a paying customer — so
-- this only decrements `where stock_qty > 0` and silently no-ops (no
-- exception, sale/AMC-sell RPC completes normally) when already at 0. The
-- gift simply doesn't get handed over in that case; gift_logs still records
-- that it was *offered/selected*, which is what invoice.gift_id / the AMC
-- plan's bundled gift already mean elsewhere in this schema.
--
-- The plain `update ... set stock_qty` below still fires the existing
-- item-type-agnostic `inventory_auto_draft_po` trigger exactly like a
-- spare/product sale would, so the already-shipped max_stock reorder
-- formula (20260729100000_reorder_max_stock_only.sql) applies to gifts for
-- free — nothing new needed for that part, per the owner's instruction to
-- reuse it rather than rewrite it. (For the reorder to actually fire, the
-- gift also needs a `supplier_products` link, same precondition as any
-- product/spare — supplier_products.item_type is this same enum column, no
-- schema change needed there; only SupplierItemsPanel.tsx's hardcoded
-- product/spare item-type toggle needs a 'gift' option, done separately.)
create or replace function public._gift_log_decrement_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.inventory
    set stock_qty = stock_qty - 1
    where org_id = new.org_id and item_type = 'gift' and item_id = new.gift_id
      and location = 'warehouse' and stock_qty > 0;

  if found then
    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (new.org_id, 'gift', new.gift_id, -1, 'gift_given', new.invoice_id);
  end if;

  return new;
end;
$$;

create or replace trigger gift_logs_decrement_stock
  after insert on public.gift_logs
  for each row execute function public._gift_log_decrement_stock();
