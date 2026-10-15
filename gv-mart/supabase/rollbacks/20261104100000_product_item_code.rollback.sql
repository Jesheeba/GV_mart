-- Rollback for 20261104100000_product_item_code.sql
alter table public.products drop column if exists item_code;
