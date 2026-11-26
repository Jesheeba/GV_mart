-- Arrival location lock (build-docs/features/arrival-location-lock.md, owner decisions 2026-11-26).
--
-- The first confirmed technician arrival at an address locks its pin as final:
--   * record_technician_arrival_address now locks once (never moves a locked pin),
--     re-checks the geofence + GPS accuracy server-side, logs old vs new pin, and
--     NO LONGER swaps a secondary address to primary (that path also copied only
--     legacy columns and silently dropped full_address/sub_area/zone/water_*).
--   * only master can unlock, with a reason (reset_address_location_verification).
--   * a guard trigger on addresses rejects any other change to a locked pin or to the
--     verified_* columns, whatever the write path (office form, customer app, RPCs).

-- 1. Lock columns ---------------------------------------------------------------
alter table public.addresses
  add column location_verified_at timestamptz,
  add column location_verified_by uuid references public.technicians (id) on delete set null;

-- 2. Audit trail: technician location vs the pin it replaced --------------------
create table public.address_location_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  address_id uuid not null references public.addresses (id) on delete cascade,
  event text not null check (event in ('verified', 'reset')),
  technician_id uuid references public.technicians (id) on delete set null,
  actor_profile_id uuid references public.profiles (id) on delete set null,
  ticket_id uuid references public.service_tickets (id) on delete set null,
  prev_lat numeric,
  prev_lng numeric,
  new_lat numeric,
  new_lng numeric,
  distance_m numeric(10, 1),
  accuracy_m numeric,
  reason text,
  created_at timestamptz not null default now()
);
create index address_location_events_address_idx on public.address_location_events (address_id, created_at desc);

alter table public.address_location_events enable row level security;
-- Read-only for staff in the org; rows are written only by the SECURITY DEFINER functions below.
create policy address_location_events_select_staff on public.address_location_events
  for select using (org_id = public.current_org_id() and public.is_staff());
revoke insert, update, delete on public.address_location_events from anon, authenticated;

-- 3. Guard trigger ---------------------------------------------------------------
-- The two functions below set the transaction-local flag app.address_location_override;
-- every other writer is blocked from changing a locked pin or the verified_* columns.
create or replace function public._guard_address_location_lock()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if coalesce(current_setting('app.address_location_override', true), '') = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- A brand-new address is never pre-verified.
    new.location_verified_at := null;
    new.location_verified_by := null;
    return new;
  end if;

  if new.location_verified_at is distinct from old.location_verified_at
     or new.location_verified_by is distinct from old.location_verified_by then
    raise exception 'Location verification can only be changed by a technician arrival or a master reset'
      using errcode = '42501';
  end if;

  if old.location_verified_at is not null
     and (new.lat is distinct from old.lat or new.lng is distinct from old.lng) then
    raise exception 'This address location was verified on site by a technician and is locked. Ask a master to reset it.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger addresses_location_lock_guard
before insert or update on public.addresses
for each row execute function public._guard_address_location_lock();

revoke all on function public._guard_address_location_lock() from public, anon, authenticated;

-- 4. Arrival: lock once ------------------------------------------------------------
-- Signature changes (adds p_accuracy_m), so drop + recreate; DROP FUNCTION drops grants,
-- re-granted below. Old queued offline payloads (no accuracy) still work via the default.
drop function if exists public.record_technician_arrival_address(uuid, uuid, numeric, numeric);

create function public.record_technician_arrival_address(
  p_org_id uuid,
  p_ticket_id uuid,
  p_lat numeric,
  p_lng numeric,
  p_accuracy_m numeric default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tech_id uuid;
  v_address_id uuid;
  v_addr record;
  v_radius integer;
  v_distance numeric;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'record_technician_arrival_address: caller is not a technician';
  end if;

  -- Only the technician assigned to this ticket.
  select t.address_id into v_address_id
  from service_tickets t
  join appointments a on a.ticket_id = t.id
  where t.id = p_ticket_id and t.org_id = p_org_id and a.technician_id = v_tech_id
  limit 1;
  if v_address_id is null then
    return;
  end if;

  -- Unusable fix: the visit itself still goes ahead, the address just isn't locked.
  if p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or (p_accuracy_m is not null and (p_accuracy_m < 0 or p_accuracy_m > 75)) then
    return;
  end if;

  select id, lat, lng, location_verified_at into v_addr
  from addresses where id = v_address_id and org_id = p_org_id;

  -- Already final, or no previous pin to compare against (the no-pin case is
  -- the parked pin-trust design's, not this feature's).
  if v_addr.id is null or v_addr.location_verified_at is not null or v_addr.lat is null or v_addr.lng is null then
    return;
  end if;

  -- Server-side geofence: the app enforces this too, but a modified client must not be
  -- able to lock arbitrary coordinates. Haversine, metres.
  select geofence_radius_job_m into v_radius from settings where org_id = p_org_id;
  v_distance := 2 * 6371000 * asin(sqrt(
    power(sin(radians(p_lat - v_addr.lat) / 2), 2)
    + cos(radians(v_addr.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - v_addr.lng) / 2), 2)
  ));
  if v_distance > coalesce(v_radius, 250) then
    return;
  end if;

  perform set_config('app.address_location_override', 'on', true);

  -- `location_verified_at is null` makes concurrent arrivals / outbox replays lock once.
  update addresses
  set lat = p_lat, lng = p_lng, pinned_at = now(), location_accuracy_m = p_accuracy_m,
      location_verified_at = now(), location_verified_by = v_tech_id, updated_at = now()
  where id = v_address_id and location_verified_at is null;

  if found then
    insert into address_location_events (
      org_id, address_id, event, technician_id, actor_profile_id, ticket_id,
      prev_lat, prev_lng, new_lat, new_lng, distance_m, accuracy_m
    ) values (
      p_org_id, v_address_id, 'verified', v_tech_id, auth.uid(), p_ticket_id,
      v_addr.lat, v_addr.lng, p_lat, p_lng, round(v_distance, 1), p_accuracy_m
    );
  end if;

  perform set_config('app.address_location_override', 'off', true);
end;
$$;

revoke all on function public.record_technician_arrival_address(uuid, uuid, numeric, numeric, numeric) from public, anon;
grant execute on function public.record_technician_arrival_address(uuid, uuid, numeric, numeric, numeric) to authenticated;

-- 5. Master reset --------------------------------------------------------------------
create function public.reset_address_location_verification(p_address_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_addr record;
begin
  if not public.is_master() then
    raise exception 'Only a master can reset a verified location' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'A reason is required to reset a verified location' using errcode = '22023';
  end if;

  select id, org_id, lat, lng, location_verified_at into v_addr
  from addresses where id = p_address_id and org_id = public.current_org_id()
  for update;
  if v_addr.id is null then
    raise exception 'Address not found' using errcode = 'P0002';
  end if;
  if v_addr.location_verified_at is null then
    return; -- nothing locked
  end if;

  perform set_config('app.address_location_override', 'on', true);
  -- The pin itself stays; only the lock is lifted, so the next arrival can re-verify it.
  update addresses set location_verified_at = null, location_verified_by = null, updated_at = now()
  where id = p_address_id;
  insert into address_location_events (org_id, address_id, event, actor_profile_id, prev_lat, prev_lng, reason)
  values (v_addr.org_id, p_address_id, 'reset', auth.uid(), v_addr.lat, v_addr.lng, trim(p_reason));
  perform set_config('app.address_location_override', 'off', true);
end;
$$;

revoke all on function public.reset_address_location_verification(uuid, text) from public, anon;
grant execute on function public.reset_address_location_verification(uuid, text) to authenticated;
