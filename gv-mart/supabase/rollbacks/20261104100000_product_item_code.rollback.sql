-- Rollback for 20261104100000_product_item_code.sql
drop index if exists public.products_item_code_unique_idx;
alter table public.products drop column if exists item_code;
