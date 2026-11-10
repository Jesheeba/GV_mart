-- Rollback for 20261104110000_invoice_quotation_item_code_snapshot.sql
drop trigger if exists aa_stamp_item_code on public.quotation_items;
drop trigger if exists aa_stamp_item_code on public.invoice_items;
drop function if exists public._stamp_item_code();
alter table public.quotation_items drop column if exists item_code;
alter table public.invoice_items drop column if exists item_code;
