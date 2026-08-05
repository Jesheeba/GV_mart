-- Per-product free-text description, admin-editable in Masters → Products,
-- shown to customers in Product Enquiry (catalog card excerpt + detail page).
alter table public.products add column if not exists description text;
