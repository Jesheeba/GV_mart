-- Rollback for 20261107100000_technician_vehicles.sql
-- Drops the two read functions, the audit trigger, both policies, the
-- indexes and the table. Does NOT drop the btree_gist extension: it is a
-- shared, instance-wide resource and other migrations may come to depend on
-- it independently of this feature -- dropping it here would be a hidden
-- side effect on anything else that starts relying on it.
begin;
revoke execute on function public.technician_vehicle_on(uuid, uuid, date) from authenticated;
revoke execute on function public.technician_own_bike_days(uuid, uuid, date) from authenticated;
drop function if exists public.technician_vehicle_on(uuid, uuid, date);
drop function if exists public.technician_own_bike_days(uuid, uuid, date);
drop trigger if exists audit_technician_vehicles on public.technician_vehicles;
drop policy if exists technician_vehicles_select_ops on public.technician_vehicles;
drop policy if exists technician_vehicles_write_ops on public.technician_vehicles;
drop index if exists public.technician_vehicles_org_id_idx;
drop index if exists public.technician_vehicles_technician_id_idx;
drop table if exists public.technician_vehicles;
commit;
notify pgrst, 'reload schema';
