-- Extends the complaint-name master (20260723132000_complaint_types_master.sql)
-- from category-only to a hybrid model: rows with product_id = null remain
-- shared category defaults (unchanged behavior), rows with product_id set
-- are scoped to that one product only. Both admin-editable from the app;
-- consuming screens merge "category default OR this product" client-side.
-- Requested directly by the client (product-specific complaint lists),
-- confirmed 2026-07-29 to keep category defaults as a fallback rather than
-- retiring them, to avoid re-entering the same complaint on every model.

alter table public.complaint_types
  add column product_id uuid references public.products (id) on delete cascade;

create index complaint_types_product_id_idx on public.complaint_types (org_id, product_id);
