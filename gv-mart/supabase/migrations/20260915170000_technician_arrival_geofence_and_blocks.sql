-- Group C (technician location confirmation), revised scope per correction:
-- the existing "Arrived" hard-block (MapPage.tsx's ARRIVAL_GEOFENCE_RADIUS_M)
-- stays a hard block — it's just now admin-configurable instead of a code
-- constant. Because arrival can only ever succeed inside the radius, the
-- "flag outside-radius for review" idea from the original proposal is
-- dropped entirely (it could never fire); what replaces it is a cheap,
-- non-blocking log of *stuck* technicians for admin visibility, and a
-- same-transaction address-confirmation step that only ever runs on an
-- already-successful (in-radius) arrival.

-- 1. Job-visit geofence radius — deliberately a separate org-wide setting
-- from geofence_radius_m (office check-in, currently 10m live): a customer's
-- house is a much looser real-world target than the office gate, and the
-- two have never been the same scale. Default matches the constant it
-- replaces (MapPage.tsx's ARRIVAL_GEOFENCE_RADIUS_M = 250) so this migration
-- is a pure config lift, not a behavior change on its own.
alter table settings
  add column geofence_radius_job_m integer not null default 250 check (geofence_radius_job_m > 0);

-- 2. Blocked-attempt log — not an approval/gating table (no decide/approve
-- flow, no notification dispatch): just a row per "technician has been
-- stuck outside the job radius for a while" episode, so admin can spot a
-- technician or address that's a repeat offender. Written client-side from
-- MapPage's existing tracking effect, same offline-outbox path as every
-- other technician write (see src/lib/offline/db.ts's file header).
create table technician_arrival_blocks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  ticket_id uuid not null references service_tickets (id) on delete cascade,
  lat numeric(9, 6) not null,
  lng numeric(9, 6) not null,
  distance_m numeric(10, 1) not null,
  radius_m integer not null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index technician_arrival_blocks_technician_id_idx on technician_arrival_blocks (technician_id, occurred_at desc);
create index technician_arrival_blocks_ticket_id_idx on technician_arrival_blocks (ticket_id);

alter table technician_arrival_blocks enable row level security;

create policy technician_arrival_blocks_select_staff on technician_arrival_blocks
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy technician_arrival_blocks_select_own on technician_arrival_blocks
  for select using (technician_id = public.current_technician_id());
create policy technician_arrival_blocks_insert_own on technician_arrival_blocks
  for insert with check (technician_id = public.current_technician_id());

-- 3. Address confirmation on successful arrival — called only from the
-- success path of MapPage's handleArrived(), i.e. only once insideArrival
-- Geofence is already true. Not a workaround for being out of range (that
-- case can't reach this function at all); it's "the technician's GPS at a
-- confirmed in-radius arrival is more trustworthy than whatever was typed
-- in at booking time."
--
-- Judgment call: if the ticket's address is already the customer's primary,
-- this just corrects that address's lat/lng in place — no new row, no
-- churn, since AMC/rental customers arrive at the same primary address
-- repeatedly and a fresh "primary" row on every single visit would leave a
-- pile of near-duplicate secondary rows with no real value. A new row
-- (copying the serviced address's text fields, demoting the previous
-- primary to secondary) is only created in the genuine swap case: the
-- ticket's address was a *different*, non-primary property, and confirming
-- it in person is what makes it become the new main address — matching the
-- literal "existing address becomes secondary" design.
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
