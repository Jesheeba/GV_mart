-- Rehearsal wrapper for 20261107100000_technician_vehicles.sql (Unit 1).
-- Refuses before 18:00 IST, refuses if the embedded migration text has been
-- edited since this wrapper was written (pinned sha256 of the LF blob),
-- fingerprints the real organisation's salaries/incentives_earned before
-- and after, EXECUTEs the migration verbatim, and ends in an unconditional
-- RAISE so nothing persists regardless of outcome. Run through the
-- Management API (database/query), never psql -- the whole call is one
-- implicit transaction and the final RAISE is what rolls it all back.
-- Read RESULTS in the error. No BEGIN/COMMIT here: that would defeat the
-- rollback.
do $wrap_vehicles$
declare
  res text := '';
  v_mig text := $mig_vehicles$
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

grant execute on function public.technician_vehicle_on(uuid, uuid, date) to authenticated;
grant execute on function public.technician_own_bike_days(uuid, uuid, date) to authenticated;
-- 20261024100000_close_public_and_anon_function_execute closed the default
-- (a function postgres creates is no longer born PUBLIC-executable), but
-- these are stated explicitly anyway rather than relying on migration
-- ordering alone.
revoke execute on function public.technician_vehicle_on(uuid, uuid, date) from public, anon;
revoke execute on function public.technician_own_bike_days(uuid, uuid, date) from public, anon;
$mig_vehicles$;
  v_expected_sha256 text := '31d42bdb64e94a3323d58ec6cd5cef82e84a90ab5edfbee8c0279dface4c0bbd';
  v_actual_sha256 text;
  v_now_ist timestamptz := now() at time zone 'Asia/Kolkata';
  v_org uuid;
  v_org_count int;
  v_fp_before text;
  v_fp_after text;
begin
  if (v_now_ist::time) < '18:00:00' then
    raise exception 'rehearsal refused: run after 18:00 IST, current IST time is %', v_now_ist::time;
  end if;

  v_actual_sha256 := encode(digest(v_mig, 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_expected_sha256 then
    raise exception 'rehearsal refused: embedded migration text does not match the pinned sha256 (expected %, got %)', v_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('sha256 pinned and verified: %s', v_actual_sha256);

  select count(*) into v_org_count from organizations where name not ilike '\_\_TEST%';
  if v_org_count <> 1 then
    raise exception 'rehearsal refused: expected exactly 1 real organisation, found %', v_org_count;
  end if;
  select id into v_org from organizations where name not ilike '\_\_TEST%' limit 1;

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_before;
  res := res || E'\n' || format('fingerprint before: %s', v_fp_before);

  execute v_mig;
  res := res || E'\n' || 'migration executed';

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_after;
  res := res || E'\n' || format('fingerprint after (expect identical, this migration touches neither table): %s -- unchanged: %s', v_fp_after, v_fp_after = v_fp_before);

  raise exception E'RESULTS%', res;
end
$wrap_vehicles$;
