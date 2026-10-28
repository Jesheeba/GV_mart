-- P4: an identification code per PRODUCT (spares already have one — `spares.sku`, 20260701090300). This is a
-- code SET by master in Inventory/Masters, printed on invoice and quotation lines — NOT a per-unit serial/IMEI.
-- Per-unit tracking (one row per physical unit, captured at sale and tied to the warranty) is a separate, larger
-- design and is explicitly held pending the owner's answer; nothing here anticipates it.
--
-- Same shape as spares.sku: plain nullable text, no DB-level check — sku itself has none either; the
-- alphanumeric/hyphen/underscore format is validated client-side only (ProductsTab.tsx), matching SparesTab.tsx's
-- own sku field exactly. Master-write only (products_write_master already covers this column — no RLS change).
--
-- A case-insensitive PARTIAL unique index: two products in the same org cannot share a code, but any number may
-- leave it null (not yet coded). Safe to add in this same migration — item_code is a brand-new column with no
-- existing rows to conflict (no backfill), so there is nothing for the index to reject at creation time.

alter table public.products
  add column item_code text;

comment on column public.products.item_code is
  'Master-set identification code for the product (not a per-unit serial). Printed on invoice/quotation lines alongside the item name.';

create unique index products_item_code_unique_idx on public.products (org_id, lower(item_code)) where item_code is not null;
