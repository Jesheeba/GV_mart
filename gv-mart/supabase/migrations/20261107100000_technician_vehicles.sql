-- Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md), Unit 1 — bike
-- ownership and petrol rate per technician, effective-dated so a mid-month
-- switch is representable (§1.2/§3.1). Overlap is rejected by the database
-- via an EXCLUDE constraint (not just the UI) — btree_gist is new to this
-- codebase, introduced here specifically because no existing table needed
-- overlap-range enforcement before.
--
-- Effective-date convention: ranges are closed-inclusive on both ends
-- (effective_to is the last day the row applies, not the day of change).
-- A switch "on the 12th" means the OLD row's effective_to is the 11th and
-- the NEW row's effective_from is the 12th — adjacent, non-overlapping,
-- inclusive ranges.

create extension if not exists btree_gist;

create table public.technician_vehicles (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  ownership text not null check (ownership in ('own', 'company')),
  petrol_rate_per_km numeric(12, 2) not null default 0 check (petrol_rate_per_km >= 0),
  effective_from date not null,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    technician_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
);

create index technician_vehicles_org_id_idx on public.technician_vehicles (org_id);
create index technician_vehicles_technician_id_idx on public.technician_vehicles (technician_id, effective_from);

alter table public.technician_vehicles enable row level security;

-- Master + operation_admin only (spec §1.8) — no policy at all for
-- technician, which is a default-deny in Postgres RLS: a technician cannot
-- read or write this table through any path.
create policy technician_vehicles_select_ops on public.technician_vehicles
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy technician_vehicles_write_ops on public.technician_vehicles for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_technician_vehicles after insert or update or delete on public.technician_vehicles
  for each row execute function public.audit_master_change();

-- "Which bike was this technician on, on this date" — a null-id row (no
-- match) is the no-vehicle-row case; callers check `.id is null`.
create or replace function public.technician_vehicle_on(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date
)
returns public.technician_vehicles
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.technician_vehicles
  where org_id = p_org_id
    and technician_id = p_technician_id
    and effective_from <= p_date
    and coalesce(effective_to, 'infinity'::date) >= p_date
  limit 1;
$$;

-- "How many days of this calendar month were they on their own bike" — sums
-- the overlap, in days, between [month start, month end) and every 'own'
-- row's [effective_from, effective_to] (inclusive), handling a technician
-- with several own/company rows across the month. Feeds Unit 5's pro-rated
-- own-bike allowance.
create or replace function public.technician_own_bike_days(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_period)::date;
  v_end date := (date_trunc('month', p_period)::date + interval '1 month')::date; -- exclusive
  v_total integer := 0;
  v_row record;
  v_seg_start date;
  v_seg_end date; -- exclusive
begin
  for v_row in
    select effective_from, effective_to
    from public.technician_vehicles
    where org_id = p_org_id
      and technician_id = p_technician_id
      and ownership = 'own'
      and effective_from < v_end
      and coalesce(effective_to, 'infinity'::date) >= v_start
  loop
    v_seg_start := greatest(v_start, v_row.effective_from);
    v_seg_end := least(v_end, coalesce(v_row.effective_to + 1, 'infinity'::date));
    if v_seg_end > v_seg_start then
      v_total := v_total + (v_seg_end - v_seg_start);
    end if;
  end loop;
  return v_total;
end;
$$;

-- ACL audit: neither function checks who is calling or which org they
-- belong to -- they trust p_org_id/p_technician_id exactly as passed. Both
-- are internal-only (called from inside compute_salary/compute_incentives,
-- which are SECURITY DEFINER and already did their own is_master()+org
-- check before reaching here; a nested call from one SECURITY DEFINER
-- function to another never needs an EXECUTE grant for the invoking role).
-- The frontend never calls either by name as an RPC today --
-- technician_own_bike_days has a service-layer wrapper and a React Query
-- hook (getTechnicianOwnBikeDays / useTechnicianOwnBikeDays) but zero
-- render call sites anywhere in src/app, so by "called directly" it does
-- not qualify either. Neither is granted to authenticated.
-- 20261024100000_close_public_and_anon_function_execute closed the default
-- (a function postgres creates is no longer born PUBLIC-executable), but
-- this is stated explicitly anyway rather than relying on migration
-- ordering alone.
revoke execute on function public.technician_vehicle_on(uuid, uuid, date) from public, anon, authenticated;
revoke execute on function public.technician_own_bike_days(uuid, uuid, date) from public, anon, authenticated;
