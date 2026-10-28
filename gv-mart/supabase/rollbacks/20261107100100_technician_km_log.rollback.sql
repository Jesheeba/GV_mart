-- Rollback for 20261107100100_technician_km_log.sql
-- Drops the three read functions, both insert policies, both select
-- policies, the indexes and the table. There is no update/delete policy to
-- drop (the migration never created one -- append-only). Existing log
-- entries are lost with the table; this is a schema rollback, not a data
-- preservation step -- export technician_km_log first if the data matters.
begin;
revoke execute on function public.technician_km_log_sum(uuid, uuid, date) from authenticated;
revoke execute on function public.technician_petrol_reference_amount(uuid, uuid, date) from authenticated;
revoke execute on function public.technician_approx_distance_km(uuid, uuid, date) from authenticated;
drop function if exists public.technician_km_log_sum(uuid, uuid, date);
drop function if exists public.technician_petrol_reference_amount(uuid, uuid, date);
drop function if exists public.technician_approx_distance_km(uuid, uuid, date);
drop policy if exists technician_km_log_select_staff on public.technician_km_log;
drop policy if exists technician_km_log_select_own on public.technician_km_log;
drop policy if exists technician_km_log_insert_own on public.technician_km_log;
drop policy if exists technician_km_log_insert_staff on public.technician_km_log;
drop index if exists public.technician_km_log_org_id_idx;
drop index if exists public.technician_km_log_technician_id_idx;
drop table if exists public.technician_km_log;
commit;
notify pgrst, 'reload schema';
