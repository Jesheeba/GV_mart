-- Rollback for 20261204170000_address_sub_area_field.sql.
alter table public.addresses drop column if exists sub_area;
