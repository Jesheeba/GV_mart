-- Rollback for held/20261015150000_set_sales_person_active.sql. Leads already moved by a deactivation stay unassigned/flagged.
drop trigger if exists guard_sales_active_client on public.profiles;
drop function if exists public.guard_sales_active_client();
drop function if exists public.set_sales_person_active(uuid, uuid, boolean);
