-- P4 part 2: a SNAPSHOT of the item's identification code on each invoice/quotation LINE, stamped at line-creation
-- time — not read from the live catalog at print time (that was the first cut of this package; replaced here).
--
-- invoice_items and quotation_items reference their item by (item_type, item_id): item_type is the enum
-- 'product' | 'spare' (20260701090000_extensions_and_enums.sql), item_id is a bare uuid with NO foreign key —
-- it is polymorphic, pointing at products.id or spares.id depending on item_type (confirmed: neither table's
-- Relationships list in the generated types names item_id; only org_id/invoice_id/quotation_id are real FKs).
-- There is no name-only matching anywhere in this path.
--
-- A BEFORE INSERT trigger on both tables resolves item_code from the catalog the moment the line is created:
-- products.item_code when item_type = 'product', spares.sku when item_type = 'spare'. It ALWAYS overwrites
-- whatever the client sent in that column (the same pattern _meeting_issue_attribution and other
-- stamp-from-session triggers in this schema use for their own column) so a line's code cannot be spoofed by a
-- direct insert.
--
-- create_sale and create_quotation are NOT edited — both insert into these tables with plain INSERT statements,
-- so the trigger fires under them exactly as it does under a direct client insert; nothing in either RPC's own
-- body needs to change. No backfill: existing rows (there are none yet in this org, since item_code on products
-- itself was only added in the previous migration) get the column but it is only ever stamped on a NEW row.
--
-- SECURITY INVOKER: a plain read of products/spares, which is already org-wide SELECT for everyone
-- (products_select_org / spares_select_org), so no elevated privilege is needed regardless of which path
-- (create_sale's own SECURITY DEFINER context, or a direct insert_sales write under invoice_items_write_sales)
-- fires the trigger.

alter table public.invoice_items add column item_code text;
alter table public.quotation_items add column item_code text;

comment on column public.invoice_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';
comment on column public.quotation_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';

create or replace function public._stamp_item_code()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.item_type = 'product' then
    select p.item_code into new.item_code from public.products p where p.id = new.item_id;
  elsif new.item_type = 'spare' then
    select s.sku into new.item_code from public.spares s where s.id = new.item_id;
  else
    new.item_code := null;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_stamp_item_code on public.invoice_items;
create trigger aa_stamp_item_code
  before insert on public.invoice_items
  for each row execute function public._stamp_item_code();

drop trigger if exists aa_stamp_item_code on public.quotation_items;
create trigger aa_stamp_item_code
  before insert on public.quotation_items
  for each row execute function public._stamp_item_code();
