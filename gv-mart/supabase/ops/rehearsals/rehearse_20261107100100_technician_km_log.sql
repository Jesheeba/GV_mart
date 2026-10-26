-- Rehearsal wrapper for 20261107100100_technician_km_log.sql (Unit 2).
-- Refuses before 18:00 IST, refuses if the embedded migration text has been
-- edited since this wrapper was written (pinned sha256 of the LF blob),
-- fingerprints the real organisation's salaries/incentives_earned before
-- and after, EXECUTEs the migration verbatim, and ends in an unconditional
-- RAISE so nothing persists regardless of outcome. Run through the
-- Management API (database/query), never psql -- the whole call is one
-- implicit transaction and the final RAISE is what rolls it all back.
-- Read RESULTS in the error. No BEGIN/COMMIT here: that would defeat the
-- rollback.
do $wrap_kmlog$
declare
  res text := '';
  v_mig text := $mig_kmlog$
-- Monthly Expenses spec, Unit 2 — kilometre log (§1.5/§3.2). Append-only: no
-- update or delete policy exists for ANY role, including master — a
-- mistaken entry is corrected with a compensating entry, never edited in
-- place, so "no code path updates or deletes a row" is enforced by the
-- database itself, not by convention. `logged_by`/nullable-on-delete-set-null
-- matches this codebase's existing audit-column convention (see
-- 20260924120100_expense_tracking_columns.sql's `expenses.logged_by`),
-- renamed from the spec's proposed `entered_by`.

create table public.technician_km_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  entry_date date not null,
  km numeric(12, 2) not null check (km > 0),
  note text,
  logged_by uuid references public.profiles (id) on delete set null default auth.uid(),
  entered_at timestamptz not null default now()
);

create index technician_km_log_org_id_idx on public.technician_km_log (org_id);
create index technician_km_log_technician_id_idx on public.technician_km_log (technician_id, entry_date);

alter table public.technician_km_log enable row level security;

create policy technician_km_log_select_staff on public.technician_km_log
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy technician_km_log_select_own on public.technician_km_log
  for select using (technician_id = public.current_technician_id());
create policy technician_km_log_insert_own on public.technician_km_log
  for insert with check (technician_id = public.current_technician_id());
create policy technician_km_log_insert_staff on public.technician_km_log
  for insert with check (org_id = public.current_org_id() and public.is_ops_staff());
-- Deliberately no update/delete policy at all (for any role) — append-only.

-- Monthly sum of the manual log — informational total shown on the salary
-- breakdown and the verification queue (§1.5). Payment for petrol is the
-- admin's verified claim amount (Unit 3/6), not this figure.
create or replace function public.technician_km_log_sum(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(km), 0)
  from public.technician_km_log
  where org_id = p_org_id
    and technician_id = p_technician_id
    and entry_date >= date_trunc('month', p_period)::date
    and entry_date < (date_trunc('month', p_period)::date + interval '1 month');
$$;

grant execute on function public.technician_km_log_sum(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_km_log_sum(uuid, uuid, date) from public, anon;

-- Petrol REFERENCE figure — not the payment. Owner revision: the bill is for
-- validation, and once a claim is verified the admin's entered amount is
-- what is paid (Unit 3/6). This exists so the admin has something to check
-- that verified amount against. Priced per entry against whichever
-- technician_vehicles row was effective on THAT entry's own date (table
-- 20261107100000_technician_vehicles.sql), not month-total-km x the rate at
-- month end — a rate changed on the 10th must not re-price the first nine
-- days, the same day-level precision technician_own_bike_days already uses
-- for ownership.
create or replace function public.technician_petrol_reference_amount(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(l.km * coalesce(v.petrol_rate_per_km, 0)), 0)
  from public.technician_km_log l
  left join public.technician_vehicles v
    on v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and v.effective_from <= l.entry_date
    and coalesce(v.effective_to, 'infinity'::date) >= l.entry_date
  where l.org_id = p_org_id
    and l.technician_id = p_technician_id
    and l.entry_date >= date_trunc('month', p_period)::date
    and l.entry_date < (date_trunc('month', p_period)::date + interval '1 month');
$$;

grant execute on function public.technician_petrol_reference_amount(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_petrol_reference_amount(uuid, uuid, date) from public, anon;

-- Approximate distance for the same technician/month, from the GPS ping
-- trail (`technician_locations`) already recorded by live tracking —
-- reference only, displayed alongside the manual log for comparison. Never
-- replaces it and is not summed into any payable figure. Nothing in this
-- codebase pre-aggregated this before; it is computed here, on read, as a
-- straight sum of Haversine distances between consecutive pings in the
-- month (R = 6371 km) — noisy by nature (GPS drift, gaps when the app is
-- closed), which is exactly why the spec treats it as a reference, not a
-- source of payment.
create or replace function public.technician_approx_distance_km(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with pings as (
    select
      lat, lng,
      lag(lat) over (order by recorded_at) as prev_lat,
      lag(lng) over (order by recorded_at) as prev_lng
    from public.technician_locations
    where org_id = p_org_id
      and technician_id = p_technician_id
      and recorded_at >= date_trunc('month', p_period)
      and recorded_at < date_trunc('month', p_period) + interval '1 month'
  )
  select coalesce(round(sum(
    2 * 6371 * asin(least(1, sqrt(
      sin(radians(lat - prev_lat) / 2) ^ 2
      + cos(radians(prev_lat)) * cos(radians(lat)) * sin(radians(lng - prev_lng) / 2) ^ 2
    )))
  )::numeric, 1), 0)
  from pings
  where prev_lat is not null and prev_lng is not null;
$$;

grant execute on function public.technician_approx_distance_km(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_approx_distance_km(uuid, uuid, date) from public, anon;
$mig_kmlog$;
  v_expected_sha256 text := '7a8f3bf2e5e3f9c8c47df819af5919a8a8265f1d76cda0f5c601135307551a01';
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
$wrap_kmlog$;
