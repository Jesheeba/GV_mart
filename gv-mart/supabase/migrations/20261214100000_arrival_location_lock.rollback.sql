-- Rollback for 20261214100000_arrival_location_lock.sql. Restores the 20260915170000
-- arrival RPC body verbatim. Drops the event log and the lock columns (their data is lost).
begin;
drop trigger if exists addresses_location_lock_guard on public.addresses;
drop function if exists public._guard_address_location_lock();
drop function if exists public.reset_address_location_verification(uuid, text);
drop function if exists public.record_technician_arrival_address(uuid, uuid, numeric, numeric, numeric);
drop table if exists public.address_location_events;
alter table public.addresses drop column if exists location_verified_at, drop column if exists location_verified_by;
create or replace function public.record_technician_arrival_address(
  p_org_id uuid,
  p_ticket_id uuid,
  p_lat numeric,
  p_lng numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_address_id uuid;
  v_customer_id uuid;
  v_is_primary boolean;
  v_old_primary_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'record_technician_arrival_address: caller is not a technician';
  end if;

  select t.address_id, t.customer_id into v_address_id, v_customer_id
  from service_tickets t
  join appointments a on a.ticket_id = t.id
  where t.id = p_ticket_id and t.org_id = p_org_id and a.technician_id = v_tech_id;

  if not found or v_address_id is null then
    -- No address on this ticket (shouldn't happen — Map requires a
    -- destination address) or the ticket isn't this technician's. Nothing
    -- to confirm; not an error the technician needs to see mid-arrival.
    return;
  end if;

  select is_primary into v_is_primary from addresses where id = v_address_id;

  if v_is_primary then
    update addresses set lat = p_lat, lng = p_lng, updated_at = now() where id = v_address_id;
    return;
  end if;

  select id into v_old_primary_id from addresses where customer_id = v_customer_id and is_primary limit 1;
  if v_old_primary_id is not null then
    update addresses set is_primary = false, updated_at = now() where id = v_old_primary_id;
  end if;

  insert into addresses (
    org_id, customer_id, door_no, flat_no, building_no, building_name, plot_no, street_cross,
    area, pincode, landmark, district, state, address_type, ownership, is_primary, lat, lng
  )
  select
    org_id, customer_id, door_no, flat_no, building_no, building_name, plot_no, street_cross,
    area, pincode, landmark, district, state, address_type, ownership, true, p_lat, p_lng
  from addresses where id = v_address_id;
end;
$$;

grant execute on function public.record_technician_arrival_address(uuid, uuid, numeric, numeric) to authenticated;
revoke all on function public.record_technician_arrival_address(uuid, uuid, numeric, numeric) from public, anon;
delete from supabase_migrations.schema_migrations where version = '20261214100000';
commit;
