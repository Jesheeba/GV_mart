-- Rollback for 20261104120000_item_code_master_update_guard.sql
drop trigger if exists guard_item_code_update on public.products;
drop function if exists public.guard_item_code_update();
