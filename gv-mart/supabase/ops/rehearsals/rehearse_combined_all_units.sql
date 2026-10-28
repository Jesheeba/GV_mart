-- Combined rehearsal wrapper -- all six Monthly Expenses migrations
-- (20261107100000 through 20261107100500), applied in order, followed by
-- all nine of this feature's SQL tests, all inside ONE DO block.
--
-- Fixed against the previous version per this review:
--   1. technician_km_log_insert_staff's existence subquery had a
--      tautology bug: `t.org_id = org_id` (unqualified) resolves inside
--      the subquery to `t.org_id = t.org_id` (always true), since
--      technicians also has a column named org_id -- not a comparison
--      against the row being inserted at all. Fixed by qualifying with
--      the outer table name (technician_km_log.org_id).
--   2. The same qualified same-organisation existence check was added to
--      technician_vehicles_write_ops (technician belongs to the row's
--      org), person_allowances_write_ops and monthly_adjustments_
--      write_ops (profile belongs to the row's org) -- none of the three
--      had this check before. Added a cross-org insert refusal test for
--      each, using a second throwaway organisation.
--   3. The control comparison below no longer switches to `authenticated`
--      before replacing a function -- CREATE OR REPLACE FUNCTION
--      requires ownership, which authenticated does not have. Each
--      replacement now runs as the owner (no role set), then role
--      switches to authenticated only for the compute_* calls, then
--      resets before anything else (including, defensively, inside the
--      exception handler).
--   4. The control technician now gets a nonzero incentive via a FIXED,
--      directly-inserted incentives_earned row -- the previous version's
--      threshold-0 incentive_rule never actually pays anything
--      (compute_incentives' own rule loop requires `threshold > 0` before
--      it inserts for this rule type), which would have made old-vs-new
--      a trivial zero-equals-zero comparison.
--
-- Standard form: refuses before 18:00 IST, using
-- (clock_timestamp() at time zone 'Asia/Kolkata')::time. Each migration's
-- and each original function body's pinned sha256 is recomputed via
-- encode(sha256(convert_to(text, 'UTF8')), 'hex') -- the built-in core
-- Postgres 13+ sha256() (bytea -> bytea), not pgcrypto's digest().
--
-- Order: fingerprint the real organisation's salaries/incentives_earned/
-- settings (settings compared with the new own_bike_allowance_base key
-- removed via jsonb `-`, since before migration 4 that column does not
-- exist yet) BEFORE migration 1 runs; recreate the believed-live bodies
-- of compute_incentives and compute_salary in their own nested BEGIN/
-- EXCEPTION sub-blocks, comparing md5(pg_get_functiondef(...)) against
-- what is actually live and rolling each sub-block back regardless of
-- the outcome (PL/pgSQL has no bare SAVEPOINT; this is the idiomatic
-- substitute) -- also before migration 1, which is before migrations 5
-- and 6 a fortiori; EXECUTE all six migrations in order; fingerprint the
-- real organisation again IMMEDIATELY, before any recompute or test, and
-- assert it is IDENTICAL to the before-migration-1 fingerprint (true by
-- construction: migrations 1-6 only add tables/columns/functions and
-- never touch an existing salaries/incentives_earned row, and nothing
-- has called compute_incentives/compute_salary yet); run all nine tests
-- (each in its own nested BEGIN/EXCEPTION, since every test is itself a
-- `do $t$ ... end $t$;` block ending in its own terminal RAISE); run the
-- "a technician with no expenses is paid the same" comparison in its OWN
-- throwaway __TEST_ organisation (its own technician, settings row and
-- one incentive_rule, plus a directly-inserted fixed incentive) -- never
-- against real technicians -- comparing that technician's result under
-- the recreated OLD bodies against the NEW (now-live) bodies; end in ONE
-- unconditional final RAISE so every migration and every test's/the
-- control comparison's already-rolled-back-or-not side effect is undone
-- together regardless. Run through the Management API (database/query),
-- never psql. Read RESULTS in the error. No BEGIN/COMMIT at the top
-- level anywhere in this file: that would defeat the rollback.
do $combo$
declare
  res text := '';
  v_now_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_org uuid;
  v_org_count int;
  v_fp_before text;
  v_fp_after_migrations text;
  v_fp_final text;
  v_actual_sha256 text;
  v_test_result text;
  v_live_inc_md5 text;
  v_recreated_inc_md5 text;
  v_live_sal_md5 text;
  v_recreated_sal_md5 text;
  -- Control-comparison (throwaway org) variables
  v_ctrl_org uuid; v_ctrl_master uuid; v_ctrl_tech uuid; v_ctrl_techp uuid;
  v_ctrl_rule_id uuid;
  v_ctrl_period date := '2026-09-01';
  v_old_incentives_baseline jsonb; v_new_incentives_check jsonb;
  v_old_salary_baseline salaries; v_new_salary_check salaries;
  v_m1 text := $m1body$
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
--
-- Note on schema placement (this review): installed into Supabase's
-- `extensions` schema, per this review's explicit instruction -- NOT the
-- local convention this codebase otherwise follows (20260701090000_
-- extensions_and_enums.sql installed pgcrypto into `public`, and every
-- function here still unqualified-calls gen_random_uuid()/digest()
-- relying on that). The EXCLUDE constraint below resolves btree_gist's
-- gist support/operator classes at the moment this CREATE TABLE runs,
-- using whatever the connection's search_path is then (Supabase's
-- platform-managed default includes `public, extensions`), so this does
-- not require `extensions` in any later function's own `set search_path`.

create extension if not exists btree_gist with schema extensions;

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
-- The existence check's outer-table qualification matters: technicians
-- also has a column named org_id, so an unqualified `t.org_id = org_id`
-- inside the subquery would resolve to `t.org_id = t.org_id` (always
-- true) rather than comparing against the row actually being written.
create policy technician_vehicles_write_ops on public.technician_vehicles for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (
    org_id = public.current_org_id()
    and public.is_ops_staff()
    and exists (
      select 1 from public.technicians t
      where t.id = technician_vehicles.technician_id
        and t.org_id = technician_vehicles.org_id
    )
  );

-- Table-level grants: ops staff read, insert and update this table
-- directly from the frontend (BikeAssignmentTab -- listTechnicianVehicle
-- History/setTechnicianVehicle/closeTechnicianVehicleRow; there is no
-- delete anywhere in the service layer, a mistaken row is corrected by
-- closing it with effective_to and opening a new one), so authenticated
-- needs select/insert/update and nothing more. The write_ops policy
-- above is what actually scopes all three to master/operation_admin
-- within their own org; a technician has no policy at all, so RLS blocks
-- every row for them regardless of this grant.
revoke all on table public.technician_vehicles from public, anon, authenticated;
grant select, insert, update on table public.technician_vehicles to authenticated;

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
$m1body$;
  v_m2 text := $m2body$
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
-- ACL audit (this review): insert_own previously checked only
-- technician_id = current_technician_id(), with NO org_id check at all --
-- a technician could insert a row for themself tagged with ANY org_id,
-- not just their own. insert_staff checked org_id = current_org_id() but
-- never verified the technician_id it was inserting for actually belongs
-- to that org -- an ops staff member could log km against a technician
-- from a different organisation entirely. Both now also require the row's
-- org_id to genuinely match the technician: insert_own via current_org_id()
-- (the technician's own org, resolved server-side, same as every other
-- self-scoped check in this codebase), insert_staff via an explicit
-- existence check against technicians.
create policy technician_km_log_insert_own on public.technician_km_log
  for insert with check (
    technician_id = public.current_technician_id()
    and org_id = public.current_org_id()
  );
-- NOTE on the fix below: `t.org_id = org_id` (unqualified) inside this
-- subquery would be a TAUTOLOGY, not a real check -- technicians also has
-- a column named org_id, so Postgres resolves the unqualified reference
-- to the subquery's OWN table (t.org_id), giving `t.org_id = t.org_id`
-- (always true) instead of comparing against the outer row's org_id. The
-- outer table name is qualified explicitly to force the comparison
-- against the actual INSERTed row, not the subquery's own alias.
create policy technician_km_log_insert_staff on public.technician_km_log
  for insert with check (
    org_id = public.current_org_id()
    and public.is_ops_staff()
    and exists (
      select 1 from public.technicians t
      where t.id = technician_km_log.technician_id
        and t.org_id = technician_km_log.org_id
    )
  );
-- Deliberately no update/delete policy at all (for any role) — append-only.

-- Table-level grants: both the technician's own screen and the admin
-- KmLogTab read and insert this table directly, so authenticated needs
-- select/insert and nothing more -- no update/delete anywhere in the
-- service layer (append-only by design), matching the absence of any
-- update/delete policy above.
revoke all on table public.technician_km_log from public, anon, authenticated;
grant select, insert on table public.technician_km_log to authenticated;

-- ACL audit (this migration's three read functions, all genuinely called
-- directly from the frontend as RPCs, confirmed against
-- src/services/monthlyExpenses.ts and every component that imports its
-- hooks): the first version of each had NO caller/org check at all — any
-- authenticated user could pass an arbitrary org_id/technician_id and read
-- another organisation's or another technician's monthly figures. All
-- three are rewritten here as plpgsql with an explicit guard that RAISEs
-- (loud refusal, matching submit_expense_claim/verify_expense_claim's own
-- convention) rather than silently filtering to an empty/zero result. The
-- guard is symmetric across all three: master/operation_admin may query
-- any technician in their org; a technician may query only themself.

-- Monthly sum of the manual log — informational total shown on the salary
-- breakdown and the verification queue (§1.5). Payment for petrol is the
-- admin's verified claim amount (Unit 3/6), not this figure. Called
-- directly by both the admin KmLogTab (any technician) and the
-- technician's own ExpensesPage (self) — see useKmLogMonthlySum.
create or replace function public.technician_km_log_sum(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_km_log_sum: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_km_log_sum: access denied';
  end if;

  return coalesce((
    select sum(km)
    from public.technician_km_log
    where org_id = p_org_id
      and technician_id = p_technician_id
      and entry_date >= date_trunc('month', p_period)::date
      and entry_date < (date_trunc('month', p_period)::date + interval '1 month')
  ), 0);
end;
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
-- for ownership. Called directly by the admin VerificationQueueTab for the
-- claim's own technician — see usePetrolReferenceAmount.
create or replace function public.technician_petrol_reference_amount(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_petrol_reference_amount: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_petrol_reference_amount: access denied';
  end if;

  return coalesce((
    select sum(l.km * coalesce(v.petrol_rate_per_km, 0))
    from public.technician_km_log l
    left join public.technician_vehicles v
      on v.org_id = p_org_id
      and v.technician_id = p_technician_id
      and v.effective_from <= l.entry_date
      and coalesce(v.effective_to, 'infinity'::date) >= l.entry_date
    where l.org_id = p_org_id
      and l.technician_id = p_technician_id
      and l.entry_date >= date_trunc('month', p_period)::date
      and l.entry_date < (date_trunc('month', p_period)::date + interval '1 month')
  ), 0);
end;
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
-- source of payment. Called directly by the admin KmLogTab for the
-- selected technician — see useApproxDistanceKm.
create or replace function public.technician_approx_distance_km(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_approx_distance_km: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_approx_distance_km: access denied';
  end if;

  return coalesce((
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
    select round(sum(
      2 * 6371 * asin(least(1, sqrt(
        sin(radians(lat - prev_lat) / 2) ^ 2
        + cos(radians(prev_lat)) * cos(radians(lat)) * sin(radians(lng - prev_lng) / 2) ^ 2
      )))
    )::numeric, 1)
    from pings
    where prev_lat is not null and prev_lng is not null
  ), 0);
end;
$$;

grant execute on function public.technician_approx_distance_km(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_approx_distance_km(uuid, uuid, date) from public, anon;
$m2body$;
  v_m3 text := $m3body$
-- Monthly Expenses spec, Unit 3 — petrol/maintenance bill submission and
-- verification (§1.4/§3.3, and the owner's revision superseding §1.3 — the
-- bill is for validation, and once verified the admin's entered amount IS
-- the payment, for petrol exactly as for maintenance). `verified_amount is
-- null` is the gate: a row with no verified_amount is invisible to salary
-- and the report through any code path, because Units 5-7 only ever read
-- verified rows. There is no separate rejected state — verifying at zero
-- behaves as a rejection, the row and photo survive, `reason` records why.
-- Both claim_types share this exact mechanism; see Unit 6 for how the
-- kilometres x rate figure is kept as a reference the admin checks the bill
-- against, never as the payment formula.
--
-- Write path matches this codebase's `payment_proofs` convention
-- (20260807092000_payment_proofs.sql): no direct client insert/update grant
-- on the table at all — the technician's identity and the claim's shape are
-- resolved and validated entirely inside the two RPCs below, never trusted
-- from client-supplied columns.

create table public.expense_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  period date not null,
  claim_type text not null check (claim_type in ('petrol', 'maintenance')),
  submitted_amount numeric(12, 2) not null check (submitted_amount >= 0),
  bill_photo_path text not null,
  submitted_at timestamptz not null default now(),
  verified_amount numeric(12, 2) check (verified_amount >= 0),
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  reason text,
  -- The whole audit trail: a verified figure that differs from what was
  -- submitted must carry a written reason, enforced here so it can never be
  -- bypassed by skipping a frontend form.
  constraint expense_claims_reason_required_if_adjusted check (
    verified_amount is null or verified_amount = submitted_amount or reason is not null
  )
);

create index expense_claims_org_id_idx on public.expense_claims (org_id);
create index expense_claims_technician_id_idx on public.expense_claims (technician_id, period);
create index expense_claims_period_idx on public.expense_claims (org_id, period) where verified_amount is not null;

alter table public.expense_claims enable row level security;

create policy expense_claims_select_staff on public.expense_claims
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy expense_claims_select_own on public.expense_claims
  for select using (technician_id = public.current_technician_id());
-- No insert/update/delete policy on the table — every write goes through
-- submit_expense_claim / verify_expense_claim below. Both are SECURITY
-- DEFINER, so their internal INSERT/UPDATE run as the function owner, not
-- as `authenticated` -- they need no table-level grant to work. The only
-- thing a client ever does directly against this table is SELECT (the two
-- policies above), so that is the only table grant given.
revoke all on table public.expense_claims from public, anon, authenticated;
grant select on table public.expense_claims to authenticated;

create trigger audit_expense_claims after insert or update or delete on public.expense_claims
  for each row execute function public.audit_master_change();

-- ── Storage: private bucket, org- AND technician-scoped path ─────────────
-- Same 5MB/image-only limits as every other photo bucket in this codebase.
-- Path shape `${orgId}/${technicianId}/${uuid}.${ext}` lets the storage
-- policy scope access per-org AND per-technician without a lookup table,
-- same idea as payment-proofs' `current_technician_id() is not null` but
-- tightened two levels further: [1] must be the caller's own org (this
-- review's fix -- the first version checked only the technician-id folder
-- segment, so a technician in org A could upload into or read from any
-- path shaped `<any org>/<their own technician id>/...`, and an
-- is_ops_staff() caller could read ANY org's photos, not just their own),
-- and [2] must be the caller's own technician id, so a technician can't
-- even upload into another technician's folder, let alone read one by
-- guessing a key.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-claim-photos', 'expense-claim-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy expense_claim_photos_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'expense-claim-photos'
  and public.current_technician_id() is not null
  and (storage.foldername(name))[1] = public.current_org_id()::text
  and (storage.foldername(name))[2] = public.current_technician_id()::text
);
create policy expense_claim_photos_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'expense-claim-photos'
  and (storage.foldername(name))[1] = public.current_org_id()::text
  and (
    public.is_ops_staff()
    or (storage.foldername(name))[2] = public.current_technician_id()::text
  )
);
-- No delete policy on the bucket or the table: proofs are permanent, same
-- posture as payment-proofs/technician-documents.

-- ── submit_expense_claim: technician uploads, identity resolved server-side ─
create or replace function public.submit_expense_claim(
  p_org_id uuid,
  p_claim_type text,
  p_submitted_amount numeric,
  p_bill_photo_path text,
  p_period date default current_date
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_claim public.expense_claims;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'submit_expense_claim: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_expense_claim: org mismatch';
  end if;
  if p_claim_type not in ('petrol', 'maintenance') then
    raise exception 'submit_expense_claim: invalid claim_type %', p_claim_type;
  end if;
  if p_submitted_amount < 0 then
    raise exception 'submit_expense_claim: submitted_amount must be non-negative';
  end if;
  if nullif(btrim(p_bill_photo_path), '') is null then
    raise exception 'submit_expense_claim: bill_photo_path is required';
  end if;
  -- The row the technician submits must point at a photo actually in
  -- their own org/technician folder -- otherwise a technician could save
  -- a claim row referencing any storage path (their own upload rights are
  -- already folder-scoped by the storage policies above, but nothing
  -- before this review stopped them pointing the ROW at a path they
  -- never uploaded to, e.g. another technician's or another org's).
  if not starts_with(p_bill_photo_path, p_org_id::text || '/' || v_tech_id::text || '/') then
    raise exception 'submit_expense_claim: bill_photo_path must be under the caller''s own org/technician folder';
  end if;

  insert into public.expense_claims (org_id, technician_id, period, claim_type, submitted_amount, bill_photo_path)
  values (p_org_id, v_tech_id, date_trunc('month', p_period)::date, p_claim_type, p_submitted_amount, p_bill_photo_path)
  returning * into v_claim;

  return v_claim;
end;
$$;

-- ACL audit: checked -- raises unless the caller resolves to a real
-- technician (current_technician_id() is not null) and the org matches.
-- Called directly from the frontend (submitExpenseClaim). Granted.
revoke execute on function public.submit_expense_claim(uuid, text, numeric, text, date) from public, anon, authenticated;
grant execute on function public.submit_expense_claim(uuid, text, numeric, text, date) to authenticated;

-- ── verify_expense_claim: master/operation_admin sets the figure that pays ──
-- `verified_amount = 0` with a reason IS the "rejected" state (§1.4) — no
-- separate status column, nothing is deleted. Re-running this on an
-- already-verified claim is allowed (an admin correcting their own earlier
-- verification), and still goes through the same reason-required check.
create or replace function public.verify_expense_claim(
  p_claim_id uuid,
  p_verified_amount numeric,
  p_reason text default null
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claim public.expense_claims;
begin
  if not public.is_ops_staff() then
    raise exception 'verify_expense_claim: master or operation_admin role required';
  end if;
  select * into v_claim from public.expense_claims where id = p_claim_id and org_id = public.current_org_id();
  if v_claim.id is null then
    raise exception 'verify_expense_claim: claim % not found', p_claim_id;
  end if;
  if p_verified_amount is null or p_verified_amount < 0 then
    raise exception 'verify_expense_claim: verified_amount must be a non-negative number';
  end if;
  if p_verified_amount is distinct from v_claim.submitted_amount and nullif(btrim(p_reason), '') is null then
    raise exception 'verify_expense_claim: reason is required when the verified amount differs from the submitted amount';
  end if;

  update public.expense_claims
  set verified_amount = p_verified_amount,
      verified_by = auth.uid(),
      verified_at = now(),
      reason = nullif(btrim(p_reason), '')
  where id = p_claim_id
  returning * into v_claim;

  return v_claim;
end;
$$;

-- ACL audit: checked -- raises unless is_ops_staff(), and the claim lookup
-- is scoped to current_org_id() (a cross-org claim id resolves v_claim.id
-- to null and raises). Called directly from the frontend
-- (verifyExpenseClaim). Granted.
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.verify_expense_claim(uuid, numeric, text) to authenticated;

-- Monthly verified totals per technician, by claim type — the figures Units
-- 6/7 read. Unverified rows are excluded by construction (verified_amount is
-- the gate).
create or replace function public.technician_expense_claims_total(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date,
  p_claim_type text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(verified_amount), 0)
  from public.expense_claims
  where org_id = p_org_id
    and technician_id = p_technician_id
    and claim_type = p_claim_type
    and period = date_trunc('month', p_period)::date
    and verified_amount is not null;
$$;

-- ACL audit: no caller/org check at all, and confirmed not called directly
-- from the frontend anywhere (grep of src/ for this name turns up nothing
-- outside this file) -- internal-only, called from inside compute_salary,
-- which already did its own is_master()+org check before reaching here.
-- Not granted to authenticated.
revoke execute on function public.technician_expense_claims_total(uuid, uuid, date, text) from public, anon, authenticated;
$m3body$;
  v_m4 text := $m4body$
-- Monthly Expenses spec, Unit 4 — recharge allowances, the generic
-- adjustment mechanism, and the own-bike allowance org setting
-- (§1.1/§1.6/§1.7/§3.4/§3.5/§3.6).
--
-- `monthly_adjustments` is the one mechanism for every top-up and exclusion
-- (§3.5), scoped to `recharge` and `bike_allowance` only. Petrol and
-- maintenance do NOT use this table — the owner's revision (superseding the
-- "override" idea originally built here) is that the verified claim amount
-- (Unit 3) already IS the figure that pays, and verifying at zero already
-- IS how an admin refuses one. A separate adjustment row on top of that
-- would be a second way to say the same thing, so this table carries no
-- `petrol`/`maintenance` target at all.

create table public.person_allowances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  -- Deliberately `profiles`, not `technicians` — §1.1: "not restricted to
  -- technicians". A profile with no row here receives no recharge, which is
  -- the whole scoping rule.
  profile_id uuid not null references public.profiles (id) on delete cascade,
  recharge_amount numeric(12, 2) not null check (recharge_amount >= 0),
  effective_from date not null,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    profile_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
);

create index person_allowances_org_id_idx on public.person_allowances (org_id);
create index person_allowances_profile_id_idx on public.person_allowances (profile_id, effective_from);

alter table public.person_allowances enable row level security;

create policy person_allowances_select_ops on public.person_allowances
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
-- The existence check's outer-table qualification matters: profiles also
-- has a column named org_id, so an unqualified `p.org_id = org_id` inside
-- the subquery would resolve to `p.org_id = p.org_id` (always true)
-- rather than comparing against the row actually being written.
create policy person_allowances_write_ops on public.person_allowances for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (
    org_id = public.current_org_id()
    and public.is_ops_staff()
    and exists (
      select 1 from public.profiles p
      where p.id = person_allowances.profile_id
        and p.org_id = person_allowances.org_id
    )
  );

-- Table-level grants: ops staff read, insert and update this table
-- directly (AllowancesTab -- listPersonAllowances/setPersonAllowance/
-- closePersonAllowanceRow by effective_to, same close-then-open pattern
-- as technician_vehicles); there is no delete anywhere in the service
-- layer, so authenticated needs select/insert/update and nothing more.
revoke all on table public.person_allowances from public, anon, authenticated;
grant select, insert, update on table public.person_allowances to authenticated;

create trigger audit_person_allowances after insert or update or delete on public.person_allowances
  for each row execute function public.audit_master_change();

create or replace function public.person_allowance_on(
  p_org_id uuid,
  p_profile_id uuid,
  p_date date
)
returns public.person_allowances
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.person_allowances
  where org_id = p_org_id
    and profile_id = p_profile_id
    and effective_from <= p_date
    and coalesce(effective_to, 'infinity'::date) >= p_date
  limit 1;
$$;

-- ACL audit: no caller/org check, and not called directly from the
-- frontend anywhere -- internal-only, called from inside compute_salary
-- (which already did its own is_master()+org check). Not granted to
-- authenticated.
revoke execute on function public.person_allowance_on(uuid, uuid, date) from public, anon, authenticated;

-- ── monthly_adjustments ────────────────────────────────────────────────────

create table public.monthly_adjustments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  period date not null,
  adjustment_target text not null check (adjustment_target in ('recharge', 'bike_allowance')),
  adjustment_type text not null check (adjustment_type in ('top_up', 'exclude')),
  amount numeric(12, 2),
  reason text not null check (btrim(reason) <> ''),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (
    (adjustment_type = 'exclude' and amount is null)
    or (adjustment_type = 'top_up' and amount is not null and amount > 0)
  )
);

create index monthly_adjustments_org_id_idx on public.monthly_adjustments (org_id);
create index monthly_adjustments_lookup_idx on public.monthly_adjustments (profile_id, period, adjustment_target);

alter table public.monthly_adjustments enable row level security;

create policy monthly_adjustments_select_ops on public.monthly_adjustments
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
-- Same qualification reasoning as person_allowances_write_ops above.
create policy monthly_adjustments_write_ops on public.monthly_adjustments for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (
    org_id = public.current_org_id()
    and public.is_ops_staff()
    and exists (
      select 1 from public.profiles p
      where p.id = monthly_adjustments.profile_id
        and p.org_id = monthly_adjustments.org_id
    )
  );

-- Table-level grants: ops staff read and insert this table directly
-- (AdjustmentsTab -- listMonthlyAdjustments/addMonthlyAdjustment); there
-- is no update or delete anywhere in the service layer (an adjustment is
-- a permanent, dated record -- correcting one means adding a new
-- adjustment row, not editing an old one), so authenticated needs select/
-- insert and nothing more.
revoke all on table public.monthly_adjustments from public, anon, authenticated;
grant select, insert on table public.monthly_adjustments to authenticated;

create trigger audit_monthly_adjustments after insert or update or delete on public.monthly_adjustments
  for each row execute function public.audit_master_change();

create or replace function public.monthly_adjustment_top_up(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount), 0)
  from public.monthly_adjustments
  where org_id = p_org_id
    and profile_id = p_profile_id
    and period = date_trunc('month', p_period)::date
    and adjustment_target = p_target
    and adjustment_type = 'top_up';
$$;

create or replace function public.monthly_adjustment_excluded(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.monthly_adjustments
    where org_id = p_org_id
      and profile_id = p_profile_id
      and period = date_trunc('month', p_period)::date
      and adjustment_target = p_target
      and adjustment_type = 'exclude'
  );
$$;

-- ACL audit: neither checks who is calling, and neither is called directly
-- from the frontend anywhere -- both internal-only, called from inside
-- compute_salary and compute_incentives (both already did their own
-- is_master()+org check). Not granted to authenticated.
revoke execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) from public, anon, authenticated;
revoke execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) from public, anon, authenticated;

-- ── Org setting: own-bike allowance base (§1.6/§3.6) ──────────────────────
-- Appended to the existing single-row-per-org `settings` table, matching
-- every other org-wide numeric config in this codebase
-- (20260701091100_system.sql's own header: "one typed row per org, not a
-- generic key/value table"). `settings_write_master` (20260701091300_rls.sql)
-- is already master-only, matching §1.6's "editable by master" exactly — no
-- RLS change needed here.
-- `audit_settings` (20260702090000_audit_triggers.sql) already covers the
-- whole row on every insert/update/delete — adding a second trigger here
-- would double-write audit_log on every settings change, so this column
-- just rides the existing trigger, no new one.
--
-- Default 1000, per spec (this review confirmed against the spec text
-- rather than assuming it): GVMART_MONTHLY_EXPENSES_SPEC.md §1.6 reads
-- "One organisation-wide base amount, defaulting to 1000, editable by
-- master."
alter table public.settings
  add column own_bike_allowance_base numeric(12, 2) not null default 1000 check (own_bike_allowance_base >= 0);
$m4body$;
  v_m5 text := $m5body$
-- Monthly Expenses spec, Unit 5 — own-bike allowance flows into
-- compute_incentives (§1.6/§1.9). This is the ONLY item from this feature
-- that touches incentives; the other three (recharge, petrol, maintenance)
-- are reimbursements and only ever appear in compute_salary (Unit 6).
--
-- Built against the REAL live body — the one after
-- 20261016150000_review_incentives_switch.sql, itself built on
-- 20261016120000_installation_incentive_credits.sql and
-- 20261016110000_test_customer_flag.sql. All three live-only components
-- are carried forward untouched: the credit_source aggregation block, the
-- _visit_is_test/_ticket_is_test exclusions, and the
-- review_incentives_enabled gate (default OFF, Google Maps policy
-- compliance) — that gate is explicitly untouchable per instruction.
--
-- incentives_earned's one-source check widens from 3-way to 4-way:
-- rule_id, installation_rate_id, credit_source, is_bike_allowance — exactly
-- one set. For any row where is_bike_allowance is false (true of every row
-- that exists today, since the column is new), the new check reduces to
--   (rule_id is not null)::int + (installation_rate_id is not null)::int + (credit_source is not null)::int = 1
-- which is exactly the live 3-way predicate — adding a false 4th term to a
-- sum changes nothing. No row the 3-way check accepted or rejected changes
-- behaviour under the 4-way check.

alter table public.incentives_earned
  add column is_bike_allowance boolean not null default false;

alter table public.incentives_earned drop constraint incentives_earned_one_source;

alter table public.incentives_earned
  add constraint incentives_earned_one_source check (
    (case when rule_id is not null then 1 else 0 end)
    + (case when installation_rate_id is not null then 1 else 0 end)
    + (case when credit_source is not null then 1 else 0 end)
    + (case when is_bike_allowance then 1 else 0 end) = 1
  );

create unique index incentives_earned_bike_allowance_unique_idx
  on public.incentives_earned (technician_id, period)
  where is_bike_allowance;

-- compute_incentives: verbatim live body (20261016150000_review_incentives_
-- switch.sql) up to and including the installation-ticket-credits block,
-- with one new block appended just before the final `return query` —
-- marked below. Nothing above that marker changed.
create or replace function public.compute_incentives(p_org_id uuid, p_period date)
 RETURNS SETOF incentives_earned
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
  v_review_enabled boolean;
  -- Unit 5 additions, own-bike allowance block only.
  v_bike_tech record;
  v_own_days integer;
  v_days_in_month integer;
  v_base_setting numeric(12, 2);
  v_prorated numeric(12, 2);
  v_extra numeric(12, 2);
  v_excluded boolean;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  -- Google's policy forbids rewarding reviews: the 'review' rule type only pays while the master has switched this ON
  -- (default OFF). Existing rules and rows are untouched; the switch only stops new computations.
  select coalesce(s.review_incentives_enabled, false) into v_review_enabled from public.settings s where s.org_id = p_org_id;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id and is_active loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      -- A rule set to ₹0 pays nothing: no zero-amount rows.
      if v_rule.amount <= 0 then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' and v_review_enabled then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and not public._visit_is_test(v.id)
          and r.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and r.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'installation' then
        v_metric := public.technician_installation_count(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  -- Per-unit installation rates (additive to the flat-threshold rule above).
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    for v_rate in
      select m.rate_id, sum(m.qty)::int as qty, ra.flat_amount
      from (
        select il.qty, public.installation_rate_for(p_org_id, il.product_id) as rate_id
        from public.installations_logged il
        where il.org_id = p_org_id
          and il.technician_id = v_tech.id
          -- already paid by an installation-ticket credit (pending or approved): never counted twice
          and not exists (
            select 1 from public.installation_incentive_credits c
            where c.visit_id = il.visit_id and c.product_id = il.product_id and c.status <> 'void'
          )
          and not public._visit_is_test(il.visit_id)
          and il.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and il.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      ) m
      join public.installation_incentive_rates ra on ra.id = m.rate_id
      group by m.rate_id, ra.flat_amount
    loop
      v_amount := v_rate.qty * v_rate.flat_amount;
      if v_amount <= 0 then
        continue;
      end if;
      select id into v_existing_id from public.incentives_earned
        where technician_id = v_tech.id and installation_rate_id = v_rate.rate_id and period = v_period;
      if v_existing_id is null then
        insert into public.incentives_earned (org_id, technician_id, installation_rate_id, amount, period)
        values (p_org_id, v_tech.id, v_rate.rate_id, v_amount, v_period);
      else
        update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
      end if;
    end loop;
  end loop;

  -- Installation-ticket credits: the master-approved credits completed in the month, one row per technician and month.
  -- Recomputed on every run (like the per-unit rates) so a late approval or a void is reflected.
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    select coalesce(sum(c.amount), 0) into v_amount
    from public.installation_incentive_credits c
    where c.org_id = p_org_id
      and c.technician_id = v_tech.id
      and c.status = 'approved'
      and c.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
      and c.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      and not public._ticket_is_test(c.ticket_id);
    select id into v_existing_id from public.incentives_earned
      where technician_id = v_tech.id and credit_source = 'installation_ticket' and period = v_period;
    if v_existing_id is null then
      if v_amount > 0 then
        insert into public.incentives_earned (org_id, technician_id, credit_source, amount, period)
        values (p_org_id, v_tech.id, 'installation_ticket', v_amount, v_period);
      end if;
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  -- ── Unit 5: own-bike allowance (new block) ──────────────────────────────
  -- Pro-rated by days-in-month on an own bike (technician_own_bike_days,
  -- Unit 1); a company-bike technician or one with no vehicle row at all
  -- gets 0 own-days and so pays 0 — "every existing component of the
  -- incentive total is unchanged" holds because this block only ever
  -- INSERTs a new is_bike_allowance row or UPDATEs one it already owns; it
  -- never touches a rule_id/installation_rate_id/credit_source row.
  --
  -- The existing-row lookup happens BEFORE the <= 0 check, deliberately: a
  -- technician can be recomputed for a period more than once (an admin
  -- switches them to a company bike or excludes them, then re-runs
  -- compute_incentives for a month already touched). If a row from an
  -- earlier, larger-amount run already exists and the new amount is <= 0,
  -- it must be zeroed, not silently left stale — "continue"-ing straight
  -- past it (the original shape of this block) would leave the technician
  -- permanently overpaid in incentives_earned until some other code path
  -- happened to delete the row, which none does.
  select own_bike_allowance_base into v_base_setting from public.settings where org_id = p_org_id;
  v_base_setting := coalesce(v_base_setting, 0);
  v_days_in_month := (v_period + interval '1 month')::date - v_period;

  for v_bike_tech in select id, profile_id from public.technicians where org_id = p_org_id and is_active loop
    v_own_days := public.technician_own_bike_days(p_org_id, v_bike_tech.id, v_period);
    v_prorated := round(v_base_setting * v_own_days / v_days_in_month, 2);
    v_excluded := public.monthly_adjustment_excluded(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_extra := public.monthly_adjustment_top_up(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_amount := (case when v_excluded then 0 else v_prorated end) + v_extra;

    select id into v_existing_id from public.incentives_earned
      where technician_id = v_bike_tech.id and period = v_period and is_bike_allowance;

    if v_amount <= 0 then
      if v_existing_id is not null then
        update public.incentives_earned set amount = 0 where id = v_existing_id and amount is distinct from 0;
      end if;
      continue;
    end if;

    if v_existing_id is null then
      insert into public.incentives_earned (org_id, technician_id, is_bike_allowance, amount, period)
      values (p_org_id, v_bike_tech.id, true, v_amount, v_period);
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;

-- ACL audit: checked -- raises unless is_master() and the org matches.
-- Called directly from the frontend (useComputeIncentives / hr.ts). Granted.
revoke execute on function public.compute_incentives(uuid, date) from public, anon, authenticated;
grant execute on function public.compute_incentives(uuid, date) to authenticated;
$m5body$;
  v_m6 text := $m6body$
-- Monthly Expenses spec, Unit 6 — four itemised lines in compute_salary
-- (§1.9/§4 Unit 6, and the owner's revision to §1.3). `compute_salary`
-- returns `salaries` (a plain row type, no existing jsonb/array-of-lines
-- concept anywhere in this codebase — see the Section 2 report), so "never
-- collapsed into a single figure" is met by adding named columns rather
-- than inventing a jsonb shape with no local precedent. No existing column
-- is removed or renamed, so a caller reading only the original 5 fields
-- sees no change.
--
-- Owner revision (supersedes the original §1.3 "km x rate is the payment"
-- design, and removes this file's earlier exclude+top_up override
-- modelling entirely): petrol now behaves exactly like maintenance —
-- `expense_claims.verified_amount` is what is paid, gated the same way
-- (null = nothing paid). Kilometres x rate is kept only as a REFERENCE
-- figure, computed per log entry against whichever technician_vehicles row
-- was effective on that entry's own date
-- (technician_petrol_reference_amount, 20261107100100_technician_km_log.sql)
-- so the admin has something to check the verified amount against. Neither
-- petrol nor maintenance reads monthly_adjustments any more — verifying at
-- zero is the refusal, the verified amount is the correction (Fix 4).
--
-- Important distinction: the own-bike allowance is NOT added to `net` here
-- a second time — Unit 5 already folds it into `incentives_earned`, and
-- `incentives` below already sums that in, same as it always has.
-- `bike_allowance_base/extra/reason` are read back from Unit 1/4/5's own
-- tables purely for display, not a second addition. Recharge/petrol/
-- maintenance ARE new additions to `net` — they didn't exist in the
-- formula before this feature.

alter table public.salaries
  add column recharge_amount numeric(12, 2) not null default 0,
  add column recharge_reason text,
  add column petrol_km numeric(12, 2) not null default 0,
  add column petrol_rate numeric(12, 2) not null default 0,
  add column petrol_reference_amount numeric(12, 2) not null default 0,
  add column petrol_amount numeric(12, 2) not null default 0,
  add column maintenance_amount numeric(12, 2) not null default 0,
  add column bike_allowance_base numeric(12, 2) not null default 0,
  add column bike_allowance_extra numeric(12, 2) not null default 0,
  add column bike_allowance_reason text,
  add column bike_allowance_amount numeric(12, 2) not null default 0;

-- compute_salary: verbatim live body (20261001110000_compute_salary_tier_
-- base.sql) with the itemised-lines block inserted before the final
-- upsert, and the recharge/petrol/maintenance totals folded into `net`
-- alongside the existing base/revenue_component/late_deduction/incentives.
create or replace function public.compute_salary(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns salaries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_base numeric(12, 2);
  v_revenue numeric(12, 2);
  v_late_hours numeric(12, 2);
  v_late_deduction numeric(12, 2);
  v_incentives numeric(12, 2);
  v_row salaries;
  -- Unit 6 additions.
  v_profile_id uuid;
  v_recharge numeric(12, 2);
  v_recharge_reason text;
  v_km numeric(12, 2);
  v_rate numeric(12, 2);
  v_petrol_reference numeric(12, 2);
  v_petrol numeric(12, 2);
  v_maintenance numeric(12, 2);
  v_bike_row incentives_earned;
  v_bike_base numeric(12, 2);
  v_bike_extra numeric(12, 2);
  v_bike_reason text;
  v_bike_amount numeric(12, 2);
begin
  if not public.is_master() then
    raise exception 'compute_salary: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_salary: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = p_org_id) then
    raise exception 'compute_salary: technician % not found in org %', p_technician_id, p_org_id;
  end if;

  select tt.monthly_salary into v_base
  from public.technicians t
  join public.technician_tiers tt on tt.id = t.tier_id
  where t.id = p_technician_id;
  if v_base is null then
    select tt.monthly_salary into v_base
    from public.technician_tiers tt
    where tt.org_id = p_org_id and tt.rank = 1;
  end if;
  v_base := coalesce(v_base, 0);

  v_revenue := public.technician_attributed_revenue(p_org_id, p_technician_id, v_period);
  v_late_hours := public.technician_late_hours(p_org_id, p_technician_id, v_period);
  -- v2.2: "late deduction hours x 2" — see original definition.
  v_late_deduction := round(v_late_hours * 2, 2);

  select coalesce(sum(amount), 0) into v_incentives
  from public.incentives_earned
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  -- ── Monthly Expenses itemised lines ──────────────────────────────────
  select profile_id into v_profile_id from public.technicians where id = p_technician_id;

  -- Recharge: a flat allowance set per person; no amount set is the whole
  -- scoping rule (§1.1). Still uses monthly_adjustments (recharge was never
  -- part of the petrol/maintenance revision).
  select coalesce(recharge_amount, 0) into v_recharge
  from public.person_allowance_on(p_org_id, v_profile_id, v_period);
  v_recharge := coalesce(v_recharge, 0);
  if public.monthly_adjustment_excluded(p_org_id, v_profile_id, v_period, 'recharge') then
    v_recharge := 0;
  end if;
  v_recharge := v_recharge + public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'recharge');
  select reason into v_recharge_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'recharge'
    order by created_at desc limit 1;

  -- Petrol — owner revision: the verified claim amount is what is paid,
  -- exactly like maintenance (see technician_expense_claims_total, Unit 3).
  -- km/rate/reference are informational only, shown so the admin can see
  -- what they checked the verified amount against; `petrol_rate` is the
  -- technician's currently-effective rate for context, while
  -- petrol_reference_amount is priced per log entry at whatever rate was
  -- effective on that entry's own date (handles a rate that changed
  -- mid-month correctly — see technician_petrol_reference_amount).
  v_km := public.technician_km_log_sum(p_org_id, p_technician_id, v_period);
  select coalesce(petrol_rate_per_km, 0) into v_rate
  from public.technician_vehicle_on(p_org_id, p_technician_id, (v_period + interval '1 month' - interval '1 day')::date);
  v_rate := coalesce(v_rate, 0);
  v_petrol_reference := public.technician_petrol_reference_amount(p_org_id, p_technician_id, v_period);
  v_petrol := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'petrol');

  -- Maintenance: only a verified claim reaches salary (§1.4) —
  -- technician_expense_claims_total already excludes unverified rows. No
  -- monthly_adjustments involvement (Fix 4): verifying at zero is the
  -- refusal, the verified amount is the correction.
  v_maintenance := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'maintenance');

  -- Own-bike allowance: display only — the figure is already inside
  -- v_incentives above via Unit 5, never added twice.
  select * into v_bike_row from public.incentives_earned
    where technician_id = p_technician_id and period = v_period and is_bike_allowance;
  select own_bike_allowance_base into v_bike_base from public.settings where org_id = p_org_id;
  v_bike_base := coalesce(v_bike_base, 0);
  v_bike_extra := public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'bike_allowance');
  select reason into v_bike_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'bike_allowance'
    order by created_at desc limit 1;
  v_bike_amount := coalesce(v_bike_row.amount, 0);

  insert into public.salaries (
    org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net,
    recharge_amount, recharge_reason, petrol_km, petrol_rate, petrol_reference_amount, petrol_amount,
    maintenance_amount, bike_allowance_base, bike_allowance_extra, bike_allowance_reason, bike_allowance_amount
  )
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives,
    v_base + v_revenue - v_late_deduction + v_incentives + v_recharge + v_petrol + v_maintenance,
    v_recharge, v_recharge_reason, v_km, v_rate, v_petrol_reference, v_petrol,
    v_maintenance, v_bike_base, v_bike_extra, v_bike_reason, v_bike_amount
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net,
    recharge_amount = excluded.recharge_amount,
    recharge_reason = excluded.recharge_reason,
    petrol_km = excluded.petrol_km,
    petrol_rate = excluded.petrol_rate,
    petrol_reference_amount = excluded.petrol_reference_amount,
    petrol_amount = excluded.petrol_amount,
    maintenance_amount = excluded.maintenance_amount,
    bike_allowance_base = excluded.bike_allowance_base,
    bike_allowance_extra = excluded.bike_allowance_extra,
    bike_allowance_reason = excluded.bike_allowance_reason,
    bike_allowance_amount = excluded.bike_allowance_amount
  returning * into v_row;

  return v_row;
end;
$$;

-- ACL audit: checked -- raises unless is_master(), the org matches, and
-- the technician exists in that org. Called directly from the frontend
-- (useComputeSalary / hr.ts). Granted.
revoke execute on function public.compute_salary(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;
$m6body$;
  v_t1 text := $t1body$
-- Rolled-back check for 20261107100000_technician_vehicles.sql. Creates its
-- own __TEST_ organisation, master, 7 technicians and a settings row --
-- never reads from or depends on whatever real data already exists. Run
-- through the Management API (database/query); it always ends in a RAISE
-- so nothing persists. Read the RESULTS in the error.
--
-- technician_vehicle_on / technician_own_bike_days are internal-only after
-- the ACL audit (no grant to public, anon OR authenticated -- only their
-- owner and the SECURITY DEFINER functions that call them internally can
-- invoke them). Every call to either below therefore runs on the raw
-- connection (no role switch), exactly how compute_salary/compute_
-- incentives reach them internally; role is switched to 'authenticated'
-- only around the table-level RLS writes/reads this migration's policies
-- actually govern.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_ok boolean;
  v_days int;
  v_row public.technician_vehicles;
  v_org2 uuid; v_tech2org uuid; v_tech2orgp uuid;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_technician_vehicles') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'tv-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('tv-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- A second, unrelated organisation and its own technician -- used only
  -- for the cross-org existence-check test below.
  insert into organizations (name) values ('__TEST_technician_vehicles_other') returning id into v_org2;
  insert into settings (org_id) values (v_org2);
  v_tech2org := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_tech2org, 'authenticated', 'authenticated', 'tv-tech-org2@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_tech2org, v_org2, '__TEST_ tech-org2', 'technician');
  insert into technicians (org_id, profile_id) values (v_org2, v_tech2org) returning id into v_tech2orgp;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Overlapping ranges rejected by the database (table write, under RLS as master)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 2.5, '2026-01-01', '2026-01-20');
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
      values (v_org, v_techp[1], 'company', 0, '2026-01-10', '2026-01-25');
    res := res || E'\n' || 'overlapping range: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlapping range: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- Current ownership resolves correctly for a technician with one row
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
  res := res || E'\n' || format('single-row resolve: ownership=%s rate=%s', v_row.ownership, v_row.petrol_rate_per_km);

  delete from technician_vehicles where technician_id = v_techp[1];

  -- Mid-month switch on the 12th of a 31-day month (January): 11 own, 20 company
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 3, '2026-01-01', '2026-01-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'company', 0, '2026-01-12', null);
  select technician_own_bike_days(v_org, v_techp[1], '2026-01-01') into v_days;
  res := res || E'\n' || format('mid-month switch own days (expect 11): %s', v_days);
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-20');
  res := res || E'\n' || format('ownership on the 20th (expect company): %s', v_row.ownership);
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-11');
  res := res || E'\n' || format('ownership on the 11th (expect own): %s', v_row.ownership);

  delete from technician_vehicles where technician_id = v_techp[1];

  -- Technician with no row: resolves to no ownership/rate, nothing crashes
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s, ownership is null = %s', v_row.id is null, v_row.ownership is null);
  select technician_own_bike_days(v_org, v_techp[1], '2026-01-01') into v_days;
  res := res || E'\n' || format('no-row own days (expect 0): %s', v_days);

  -- ACL audit: neither function is granted to authenticated at all -- a
  -- direct RPC call as any real authenticated session, even master, must
  -- fail on permission, not business logic.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
    res := res || E'\n' || 'master calls technician_vehicle_on directly as authenticated: SUCCEEDED (bad, should have no grant)';
  exception when others then
    res := res || E'\n' || 'master calls technician_vehicle_on directly as authenticated: rejected ('||sqlerrm||')';
  end;

  -- A technician cannot read or write this table (table RLS, independent
  -- of the two functions above)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
    values (v_org, v_techp[1], 'own', 3, '2026-02-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) = 0 into v_ok from technician_vehicles where technician_id = v_techp[1];
  res := res || E'\n' || format('technician SELECT sees nothing: %s', v_ok);
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
      values (v_org, v_techp[1], 'own', 1, '2026-03-01');
    res := res || E'\n' || 'technician INSERT: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician INSERT: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- CROSS-ORG CHECK (write_ops existence check, this review's fix):
  -- master (ops staff of v_org) tries to insert a row with org_id = v_org
  -- (their own org) but technician_id pointing at a technician who
  -- actually belongs to v_org2. Before this fix, write_ops never
  -- verified that relationship at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
      values (v_org, v_tech2orgp, 'own', 2, '2026-04-01');
    res := res || E'\n' || 'CROSS-ORG: master inserts for a technician who belongs to a different org: SUCCEEDED (bad)';
  exception when others then
    if sqlstate <> '42501' then
      res := res || E'\n' || 'CROSS-ORG: master inserts for a technician who belongs to a different org: WRONG ERROR (not a policy refusal): '||sqlerrm;
    else
      res := res || E'\n' || 'CROSS-ORG: master inserts for a technician who belongs to a different org: rejected ('||sqlerrm||')';
    end if;
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t1body$;
  v_t2 text := $t2body$
-- Rolled-back check for 20261107100100_technician_km_log.sql. Creates its
-- own __TEST_ organisation, master, 7 technicians and a settings row --
-- never reads from or depends on whatever real data already exists. Run
-- through the Management API (database/query); it always ends in a RAISE
-- so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_sum numeric; v_id uuid; v_n int;
  v_org2 uuid; v_master2 uuid; v_tech2org uuid; v_tech2orgp uuid;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_technician_km_log') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'kl-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('kl-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- A second, unrelated organisation and its own technician -- used only
  -- for the two cross-org insert checks below.
  insert into organizations (name) values ('__TEST_technician_km_log_other') returning id into v_org2;
  insert into settings (org_id) values (v_org2);
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'kl-master2@test.invalid')
    returning id into v_master2;
  insert into profiles (id, org_id, full_name, role) values (v_master2, v_org2, '__TEST_ master2', 'master');
  v_tech2org := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_tech2org, 'authenticated', 'authenticated', 'kl-tech-org2@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_tech2org, v_org2, '__TEST_ tech-org2', 'technician');
  insert into technicians (org_id, profile_id) values (v_org2, v_tech2org) returning id into v_tech2orgp;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Entries accumulate; the monthly sum is the sum of entries
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-05', 10);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-20', 15.5);
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('monthly sum (expect 25.5): %s', v_sum);

  -- An entry dated outside the filtered range does not appear and does not count
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-02-01', 99);
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('January sum unaffected by February entry (expect 25.5): %s', v_sum);

  -- The monthly sum for a technician with no entries is zero, not null
  select technician_km_log_sum(v_org, v_techp[2], '2026-01-01') into v_sum;
  res := res || E'\n' || format('no-entries sum (expect 0, not null): %s, is null = %s', v_sum, v_sum is null);

  -- Master (is_ops_staff) can read any technician's sum in-org
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('master reads technician1 sum (expect 25.5): %s', v_sum);

  -- There is no code path that updates or deletes an entry — default-deny:
  -- no update/delete policy exists at all, even for master. Checked as
  -- 'authenticated'/master, not the superuser connection running this
  -- block, since RLS does not apply to a superuser/BYPASSRLS role at all
  -- regardless of policies.
  select id into v_id from technician_km_log where technician_id = v_techp[1] order by entry_date limit 1;
  begin
    update technician_km_log set km = 1 where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('UPDATE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'UPDATE km_log as master: rejected ('||sqlerrm||')';
  end;
  begin
    delete from technician_km_log where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('DELETE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'DELETE km_log as master: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- A technician reads only their own entries, and technician_km_log_sum
  -- refuses for another technician's id (ACL audit fix: this function used
  -- to have no caller/org check at all).
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[2], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_km_log where technician_id = v_techp[1];
  res := res || E'\n' || format('technician2 sees technician1 rows (expect 0): %s', v_n);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[2], '2026-01-07', 5);
  select count(*) into v_n from technician_km_log where technician_id = v_techp[2];
  res := res || E'\n' || format('technician2 sees own rows after own insert (expect 1): %s', v_n);
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-08', 5);
    res := res || E'\n' || 'technician2 INSERT for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 INSERT for technician1: rejected ('||sqlerrm||')';
  end;
  select technician_km_log_sum(v_org, v_techp[2], '2026-01-01') into v_sum;
  res := res || E'\n' || format('technician2 reads own sum via RPC (expect 5): %s', v_sum);
  begin
    perform technician_km_log_sum(v_org, v_techp[1], '2026-01-01');
    res := res || E'\n' || 'technician2 calls technician_km_log_sum for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 calls technician_km_log_sum for technician1: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- CROSS-ORG CHECK 1 (insert_own, this review's fix): technician 3 (a
  -- real member of v_org) tries to insert a km_log row tagged with
  -- v_org2 -- their own org, not the row's. Before this fix, insert_own
  -- checked only technician_id, with no org_id condition at all, so this
  -- would have succeeded.
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[3], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org2, v_techp[3], '2026-01-09', 5);
    res := res || E'\n' || 'CROSS-ORG 1: technician3 inserts tagged with the OTHER org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG 1: technician3 inserts tagged with the OTHER org: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- CROSS-ORG CHECK 2 (insert_staff, this review's fix): master (ops
  -- staff of v_org) tries to insert a row with org_id = v_org (their own
  -- org, satisfying the old check) but technician_id pointing at a
  -- technician who actually belongs to v_org2. Before this fix,
  -- insert_staff never verified that relationship, so this would have
  -- succeeded and logged km against a technician in a different
  -- organisation entirely.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_tech2orgp, '2026-01-09', 5);
    res := res || E'\n' || 'CROSS-ORG 2: master inserts for a technician who belongs to a different org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG 2: master inserts for a technician who belongs to a different org: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t2body$;
  v_t3 text := $t3body$
-- Rolled-back check for 20261107100200_expense_claims.sql. Creates its own
-- __TEST_ organisation, master, 7 technicians and a settings row -- never
-- reads from or depends on whatever real data already exists. Run through
-- the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
--
-- Not exercised here (needs the real Storage HTTP API, not plain SQL): bucket
-- file_size_limit / allowed_mime_types enforcement on an actual upload. The
-- storage.objects RLS policies themselves are checked below.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_claim public.expense_claims; v_n int;
  v_salary salaries;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_expense_claims') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'ec-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('ec-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- Technician submits a claim via the RPC (identity resolved server-side).
  -- bill_photo_path must be shaped <org_id>/<technician_id>/<file> -- this
  -- review's fix (Unit 3) -- so it starts with the caller's own org and
  -- technician id, exactly as the storage policies' folder layout and
  -- uploadExpenseClaimPhoto() both already build it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- A path missing the org_id prefix (or any other shape) is refused.
  begin
    perform submit_expense_claim(v_org, 'maintenance', 500, v_techp[1]::text || '/bill1.jpg', '2026-01-01');
    res := res || E'\n' || 'bill_photo_path without the org_id prefix: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'bill_photo_path without the org_id prefix: rejected ('||sqlerrm||')';
  end;
  -- A path under a DIFFERENT technician's folder (even the caller's own
  -- org) is refused too.
  begin
    perform submit_expense_claim(v_org, 'maintenance', 500, v_org::text || '/' || v_techp[2]::text || '/bill1.jpg', '2026-01-01');
    res := res || E'\n' || 'bill_photo_path under a different technician''s folder: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'bill_photo_path under a different technician''s folder: rejected ('||sqlerrm||')';
  end;

  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 500, v_org::text || '/' || v_techp[1]::text || '/bill1.jpg', '2026-01-01');
  execute 'reset role';
  res := res || E'\n' || format('submitted claim with the correct path shape: verified_amount is null = %s', v_claim.verified_amount is null);

  -- A claim with verified_amount null is invisible to salary/the report.
  -- technician_expense_claims_total itself is internal-only now (ACL
  -- audit: no caller/org check, not granted to any role at all except its
  -- owner) -- so this is checked the way the real app actually reaches it,
  -- through compute_salary, which is granted and calls it internally.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('unverified claim excluded from compute_salary.maintenance_amount (expect 0): %s', v_salary.maintenance_amount);

  -- verified_amount differing from submitted_amount with a null reason is
  -- rejected by the database (CHECK constraint), not just the form
  begin
    perform verify_expense_claim(v_claim.id, 300, null);
    res := res || E'\n' || 'verify with differing amount + null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'verify with differing amount + null reason: rejected ('||sqlerrm||')';
  end;

  -- Same amount, no reason needed: succeeds
  select * into v_claim from verify_expense_claim(v_claim.id, 500, null);
  res := res || E'\n' || format('verify same amount, no reason: verified_amount=%s', v_claim.verified_amount);
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('verified claim total via compute_salary (expect 500): %s', v_salary.maintenance_amount);

  -- A verified amount of zero behaves as a rejection: nothing paid, row and
  -- photo path survive, reason is readable
  select * into v_claim from verify_expense_claim(v_claim.id, 0, 'bill illegible, rejected');
  res := res || E'\n' || format('verify at zero: verified_amount=%s reason=%s photo_survives=%s', v_claim.verified_amount, v_claim.reason, v_claim.bill_photo_path is not null);
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('total after zero-verify via compute_salary (expect 0): %s', v_salary.maintenance_amount);
  select count(*) into v_n from expense_claims where id = v_claim.id;
  res := res || E'\n' || format('row still exists after zero-verify (expect 1): %s', v_n);
  execute 'reset role';

  -- A technician cannot read another technician's claim
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[2], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from expense_claims where technician_id = v_techp[1];
  res := res || E'\n' || format('technician2 reading technician1 claims (expect 0): %s', v_n);
  begin
    perform verify_expense_claim(v_claim.id, 1, 'trying to verify as a technician');
    res := res || E'\n' || 'technician verify_expense_claim: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician verify_expense_claim: rejected ('||sqlerrm||')';
  end;
  begin
    perform technician_expense_claims_total(v_org, v_techp[1], '2026-01-01', 'maintenance');
    res := res || E'\n' || 'technician2 calls technician_expense_claims_total directly: SUCCEEDED (expect FAIL, not granted at all -- ACL audit)';
  exception when others then
    res := res || E'\n' || 'technician2 calls technician_expense_claims_total directly: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- The photograph bucket is not publicly reachable without authentication
  execute 'set local role anon';
  select count(*) into v_n from storage.objects where bucket_id = 'expense-claim-photos';
  res := res || E'\n' || format('anon SELECT on expense-claim-photos bucket rows (expect 0): %s', v_n);
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t3body$;
  v_t4 text := $t4body$
-- Rolled-back check for 20261107100300_person_allowances_and_adjustments.sql.
-- Creates its own __TEST_ organisation, master, 7 technicians and a
-- settings row -- never reads from or depends on whatever real data
-- already exists. Run through the Management API (database/query); it
-- always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
--
-- person_allowance_on / monthly_adjustment_top_up / monthly_adjustment_
-- excluded are internal-only after the ACL audit (no grant to public,
-- anon OR authenticated at all -- only their owner, and the SECURITY
-- DEFINER functions that call them internally, can invoke them). The
-- logic checks below therefore run on the raw connection (no role switch:
-- the Management API connection is not subject to RLS or EXECUTE grants
-- at all), exactly how compute_salary/compute_incentives would reach them
-- internally. Only the final cross-org visibility check switches role,
-- since that checks a table's RLS policy, not a function grant.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_org2 uuid; v_master2 uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_row public.person_allowances;
  v_n int; v_base numeric; v_excluded boolean;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_person_allowances') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'pa-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('pa-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- A second organisation, for the cross-org visibility check at the end --
  -- also self-created, not picked from whatever real orgs exist.
  insert into organizations (name) values ('__TEST_person_allowances_other') returning id into v_org2;
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'pa-master2@test.invalid')
    returning id into v_master2;
  insert into profiles (id, org_id, full_name, role) values (v_master2, v_org2, '__TEST_ master2', 'master');

  -- A person with no person_allowances row receives no recharge
  select * into v_row from person_allowance_on(v_org, v_tech[2], '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s', v_row.id is null);

  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_tech[1], 300, '2026-01-01');

  -- A top-up with a null reason is rejected by the database
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_tech[1], '2026-01-01', 'recharge', 'top_up', 200, null);
    res := res || E'\n' || 'top_up with null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'top_up with null reason: rejected ('||sqlerrm||')';
  end;

  -- A top-up with a reason succeeds and sums correctly
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[1], '2026-01-01', 'recharge', 'top_up', 200, 'extra data plan this month');
  select monthly_adjustment_top_up(v_org, v_tech[1], '2026-01-01', 'recharge') into v_base;
  res := res || E'\n' || format('recharge top-up total (expect 200): %s', v_base);

  -- An exclusion for one month affects that month only
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[1], '2026-02-01', 'recharge', 'exclude', null, 'customer complaint, withheld for February');
  select monthly_adjustment_excluded(v_org, v_tech[1], '2026-02-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('February excluded (expect true): %s', v_excluded);
  select monthly_adjustment_excluded(v_org, v_tech[1], '2026-01-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('January NOT excluded (expect false): %s', v_excluded);

  -- Ending a person's allowance row stops future months without altering past ones
  update person_allowances set effective_to = '2026-01-31' where profile_id = v_tech[1];
  select * into v_row from person_allowance_on(v_org, v_tech[1], '2026-01-15');
  res := res || E'\n' || format('January still resolves (expect 300): %s', v_row.recharge_amount);
  select * into v_row from person_allowance_on(v_org, v_tech[1], '2026-03-01');
  res := res || E'\n' || format('March after ending the row (expect id is null): %s', v_row.id is null);

  -- ACL audit: none of the three functions above is granted to
  -- authenticated at all (internal-only) -- a direct RPC call as any real
  -- authenticated session, even master, must fail on permission, not
  -- business logic.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform person_allowance_on(v_org, v_tech[1], '2026-01-15');
    res := res || E'\n' || 'master calls person_allowance_on directly as authenticated: SUCCEEDED (bad, should have no grant)';
  exception when others then
    res := res || E'\n' || 'master calls person_allowance_on directly as authenticated: rejected ('||sqlerrm||')';
  end;

  -- An adjustment belonging to another organisation is not visible or
  -- applicable -- this one checks the table's RLS policy, not a function
  -- grant, so the role switch is meaningful here.
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from monthly_adjustments where profile_id = v_tech[1];
  res := res || E'\n' || format('other-org master sees this org''s adjustments (expect 0): %s', v_n);
  execute 'reset role';

  -- CROSS-ORG CHECKS (write_ops existence checks, this review's fix):
  -- master (ops staff of v_org) tries to insert tagged with org_id = v_org
  -- (their own org) but profile_id = v_master2, a real profile that
  -- belongs to v_org2. Before this fix, neither write_ops policy verified
  -- that relationship at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
      values (v_org, v_master2, 300, '2026-04-01');
    res := res || E'\n' || 'CROSS-ORG person_allowances: master inserts for a profile from a different org: SUCCEEDED (bad)';
  exception when others then
    if sqlstate <> '42501' then
      res := res || E'\n' || 'CROSS-ORG person_allowances: master inserts for a profile from a different org: WRONG ERROR (not a policy refusal): '||sqlerrm;
    else
      res := res || E'\n' || 'CROSS-ORG person_allowances: master inserts for a profile from a different org: rejected ('||sqlerrm||')';
    end if;
  end;
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_master2, '2026-04-01', 'recharge', 'top_up', 100, 'cross-org check');
    res := res || E'\n' || 'CROSS-ORG monthly_adjustments: master inserts for a profile from a different org: SUCCEEDED (bad)';
  exception when others then
    if sqlstate <> '42501' then
      res := res || E'\n' || 'CROSS-ORG monthly_adjustments: master inserts for a profile from a different org: WRONG ERROR (not a policy refusal): '||sqlerrm;
    else
      res := res || E'\n' || 'CROSS-ORG monthly_adjustments: master inserts for a profile from a different org: rejected ('||sqlerrm||')';
    end if;
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t4body$;
  v_t5 text := $t5body$
-- Rolled-back check for 20261107100400_compute_incentives_bike_allowance.sql,
-- rebuilt against the real live body (after 20261016150000_review_
-- incentives_switch, itself after 20261016120000_installation_incentive_
-- credits and 20261016110000_test_customer_flag). Creates its own 7
-- technicians in its own __TEST_ organisation so this test's incentive_
-- rules/credit rows never interact with another org's data. Run through
-- the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_amount numeric; v_n int; v_base numeric; v_reason text;
  v_before_count int; v_after_count int;
  v_rule_id uuid;
  v_credit_row incentives_earned;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_monthly_expenses_bike_allowance') returning id into v_org;
  insert into settings (org_id) values (v_org);
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'bike-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('bike-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Technician on their own bike all month receives the full base amount
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[1] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('own all month (expect base=%s): %s', v_base, v_amount);

  -- Technician on a company bike all month receives nothing
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[2], 'company', 0, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_techp[2] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('company all month, rows created (expect 0): %s', v_n);

  -- Mid-month switch (own 1-11, company 12-30 in a 30-day April)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[3], 'own', 2, '2026-04-01', '2026-04-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[3], 'company', 0, '2026-04-12', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[3] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('mid-month switch (expect round(%s*11/30,2)=%s): %s', v_base, round(v_base * 11 / 30, 2), v_amount);

  -- An extra with a reason adds on top, and the reason is retrievable
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[3], '2026-04-01', 'bike_allowance', 'top_up', 150, 'new tyres this month, approved by master');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[3] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('with extra (expect prorated+150=%s): %s', round(v_base * 11 / 30, 2) + 150, v_amount);
  select reason into v_reason from monthly_adjustments where profile_id = v_tech[3] and adjustment_target = 'bike_allowance' limit 1;
  res := res || E'\n' || format('extra reason retrievable: %s', v_reason);

  -- Every existing component of the incentive total is unchanged: a
  -- technician with NO vehicle row produces no bike-allowance row, and
  -- re-running compute_incentives for them is a no-op (idempotent).
  select count(*) into v_before_count from incentives_earned where technician_id = v_techp[4] and period = '2026-04-01';
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_after_count from incentives_earned where technician_id = v_techp[4] and period = '2026-04-01';
  res := res || E'\n' || format('no-vehicle technician row count before=%s after=%s (expect equal)', v_before_count, v_after_count);
  select count(*) into v_n from incentives_earned where technician_id = v_techp[4] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('no-vehicle technician bike-allowance rows (expect 0): %s', v_n);

  -- FIX (this review): own bike -> recompute -> switch to company bike ->
  -- recompute -> the existing is_bike_allowance row must be zeroed, not
  -- left stale at the earlier non-zero amount. Technician 5, full April on
  -- own bike first.
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[5], 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[5] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('fix-check technician5, own all month before switch (expect base=%s): %s', v_base, v_amount);
  update technician_vehicles set ownership = 'company', petrol_rate_per_km = 0
    where technician_id = v_techp[5] and effective_from = '2026-04-01';
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[5] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('fix-check technician5, same row re-zeroed after switching to company and recomputing (expect 0, NOT the stale %s): %s', v_base, v_amount);

  -- FIX, separately: own bike -> recompute (nonzero row exists) -> admin
  -- excludes the month -> recompute -> the row must be zeroed. Technician 6.
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[6], 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[6] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('fix-check technician6, own all month before exclusion (expect base=%s): %s', v_base, v_amount);
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[6], '2026-04-01', 'bike_allowance', 'exclude', null, 'bike was actually company-owned, data entry corrected after the fact');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[6] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('fix-check technician6, same row re-zeroed after excluding and recomputing (expect 0, NOT the stale %s): %s', v_base, v_amount);

  -- The bike-allowance row and a credit_source row coexist for the same
  -- technician/period without violating the widened 4-way constraint
  -- (the credit row is inserted directly here, bypassing the real ticket/
  -- approval flow, which is out of scope for this test). The live
  -- installation-ticket-credits block recomputes its figure from
  -- installation_incentive_credits on EVERY run regardless of what this
  -- feature does — with no real backing credit row, the verbatim-preserved
  -- block correctly overwrites the manually-seeded 500 down to 0. That is
  -- the real live behaviour (by design, so a late void is reflected) and
  -- confirms the bike-allowance block did not change it: it is testing the
  -- live block exactly as it already worked before this feature existed.
  insert into incentives_earned (org_id, technician_id, credit_source, amount, period)
    values (v_org, v_techp[1], 'installation_ticket', 500, '2026-04-01');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_techp[1] and period = '2026-04-01';
  res := res || E'\n' || format('bike-allowance + credit_source coexist for same technician/period (expect 2 rows): %s', v_n);
  select * into v_credit_row from incentives_earned where technician_id = v_techp[1] and period = '2026-04-01' and credit_source = 'installation_ticket';
  res := res || E'\n' || format('credit_source row recomputed from the (empty) real credits table, unrelated to this feature (expect 0, not the seeded 500): %s', v_credit_row.amount);

  -- The review_incentives_enabled switch (default OFF) does not affect the
  -- bike-allowance block either way.
  update settings set review_incentives_enabled = true where org_id = v_org;
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_techp[1] and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('bike allowance unaffected by review switch ON (still expect base=%s): %s', v_base, v_amount);

  -- Malformed rows: the widened 4-way check still rejects two sources set,
  -- and still rejects zero sources set — exactly what the narrower 3-way
  -- check (installation_incentive_credits) already rejected.
  insert into incentive_rules (org_id, type, threshold, amount) values (v_org, 'service_income', 1000, 100) returning id into v_rule_id;
  begin
    insert into incentives_earned (org_id, technician_id, rule_id, installation_rate_id, amount, period)
      values (v_org, v_techp[2], v_rule_id, gen_random_uuid(), 10, '2026-04-01');
    res := res || E'\n' || 'two sources set: SUCCEEDED (bad, unless no incentive_rules row exists to reference)';
  exception when others then
    res := res || E'\n' || 'two sources set: rejected ('||sqlerrm||')';
  end;
  begin
    insert into incentives_earned (org_id, technician_id, amount, period) values (v_org, v_techp[2], 10, '2026-04-01');
    res := res || E'\n' || 'zero sources set: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'zero sources set: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t5body$;
  v_t6 text := $t6body$
-- Rolled-back check for 20261107100500_compute_salary_itemised_expenses.sql.
-- Creates its own __TEST_ organisation, master, 7 technicians and a
-- settings row -- never reads from or depends on whatever real data
-- already exists. Run through the Management API (database/query); it
-- always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
--
-- Not exercised here (needs a browser): "if the return shape changed, the
-- frontend renders the new shape correctly" — verified instead by the
-- SalaryTab.tsx/hr.ts SalaryRow type update described in the build report.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_row salaries; v_row2 salaries;
  v_petrol_claim public.expense_claims;
  v_maint_claim public.expense_claims;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_compute_salary_itemised') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'cs-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('cs-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- A technician with none of the four produces salary output identical to
  -- before this feature: all four new areas are 0 and net reduces to the
  -- original base + revenue_component - late_deduction + incentives formula.
  select * into v_row2 from compute_salary(v_org, v_techp[2], '2026-05-01');
  res := res || E'\n' || format(
    'no-data technician: recharge=%s petrol_amount=%s petrol_reference=%s maintenance=%s bike_extra=%s, net == old formula: %s',
    v_row2.recharge_amount, v_row2.petrol_amount, v_row2.petrol_reference_amount, v_row2.maintenance_amount, v_row2.bike_allowance_extra,
    v_row2.net = v_row2.base + v_row2.revenue_component - v_row2.late_deduction + v_row2.incentives
  );

  -- Set up all four for technician 1: recharge allowance, vehicle+km
  -- (petrol reference), a verified petrol claim, a verified maintenance
  -- claim, and own-bike allowance (via Unit 1/5).
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_tech[1], 250, '2026-05-01');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 4, '2026-05-01', '2026-05-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-05-10', 50);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_petrol_claim from submit_expense_claim(v_org, 'petrol', 150, v_org::text || '/' || v_techp[1]::text || '/petrol_bill.jpg', '2026-05-01');
  select * into v_maint_claim from submit_expense_claim(v_org, 'maintenance', 300, v_org::text || '/' || v_techp[1]::text || '/bill.jpg', '2026-05-01');
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  -- Verified lower than the reference figure (km*rate=200) — the admin's
  -- judgement call is what pays, the reference figure is just context.
  perform verify_expense_claim(v_petrol_claim.id, 180, 'bill partly illegible, approved a reduced amount');
  perform verify_expense_claim(v_maint_claim.id, 300, null);
  perform compute_incentives(v_org, '2026-05-01');

  select * into v_row from compute_salary(v_org, v_techp[1], '2026-05-01');

  -- All four lines appear separately
  res := res || E'\n' || format(
    'all-four technician: recharge=%s petrol_amount=%s maintenance=%s bike_allowance_amount=%s',
    v_row.recharge_amount, v_row.petrol_amount, v_row.maintenance_amount, v_row.bike_allowance_amount
  );

  -- The petrol line shows kilometres, the rate, the computed reference
  -- figure, AND the amount actually paid — four values, verified amount (180)
  -- is what's paid, the reference figure (km*rate=200) is informational only.
  res := res || E'\n' || format(
    'petrol breakdown: km=%s rate=%s reference=%s(expect 200) paid=%s(expect 180, NOT the reference figure)',
    v_row.petrol_km, v_row.petrol_rate, v_row.petrol_reference_amount, v_row.petrol_amount
  );

  -- The itemised lines sum to the totals the function reports (petrol_amount
  -- is the verified/paid figure, not the reference)
  res := res || E'\n' || format(
    'net reconciles: %s (net=%s, sum=%s)',
    v_row.net = v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount,
    v_row.net,
    v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount
  );

  -- A petrol claim with verified_amount null pays nothing, same gate as
  -- maintenance, and no monthly_adjustments involvement is needed any more.
  declare v_pending public.expense_claims; v_row3 salaries;
  begin
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_tech[3], 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_pending from submit_expense_claim(v_org, 'petrol', 500, v_org::text || '/' || v_techp[3]::text || '/bill.jpg', '2026-05-01');
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_row3 from compute_salary(v_org, v_techp[3], '2026-05-01');
    res := res || E'\n' || format('unverified petrol claim pays nothing (expect 0): %s', v_row3.petrol_amount);
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t6body$;
  v_t7 text := $t7body$
-- Rolled-back check for Unit 7 (monthly report). The report itself is a
-- frontend aggregation over `salaries` (see src/services/monthlyExpenses.ts's
-- getMonthlyExpensesReport) — same convention as every other report tab in
-- this codebase (no SQL view/function). This test verifies the invariants
-- that aggregation depends on: unverified claims and excluded amounts never
-- reach `salaries` in the first place, and the per-technician figures sum
-- to the org total by construction (plain SUM over the same column).
-- Creates its own __TEST_ organisation, master, 7 technicians and a
-- settings row -- never reads from or depends on whatever real data
-- already exists. Run through the Management API (database/query); it
-- always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_claim public.expense_claims;
  v_sum numeric; v_org_total numeric;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_monthly_expenses_report') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'mr-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('mr-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- Submitted as the technician (submit_expense_claim resolves identity
  -- from current_technician_id(), so the caller must actually be one).
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 400, v_org::text || '/' || v_techp[1]::text || '/bill.jpg', '2026-06-01');
  execute 'reset role';

  -- An unverified maintenance claim never reaches salary / the report
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform compute_salary(v_org, v_techp[1], '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_techp[1] and period = '2026-06-01';
  res := res || E'\n' || format('unverified claim excluded from salaries.maintenance_amount (expect 0): %s', v_sum);

  -- Verify it, then re-verify at zero — Fix 4: neither petrol nor
  -- maintenance uses monthly_adjustments any more; re-verifying at zero IS
  -- how an admin withholds a previously-verified claim. The report (reading
  -- salaries) must show 0, not the earlier verified figure.
  perform verify_expense_claim(v_claim.id, 400, null);
  perform compute_salary(v_org, v_techp[1], '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_techp[1] and period = '2026-06-01';
  res := res || E'\n' || format('verified claim reaches salary before withholding (expect 400): %s', v_sum);

  perform verify_expense_claim(v_claim.id, 0, 'disputed bill, withheld pending review');
  perform compute_salary(v_org, v_techp[1], '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_techp[1] and period = '2026-06-01';
  res := res || E'\n' || format('withheld (re-verified at zero) shows 0 in salaries (expect 0): %s', v_sum);

  -- The organisation total equals the sum of the per-technician figures
  perform compute_salary(v_org, v_techp[2], '2026-06-01');
  select sum(maintenance_amount + recharge_amount + petrol_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-06-01' and technician_id in (v_techp[1], v_techp[2]);
  select coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_techp[1] and period='2026-06-01'), 0)
       + coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_techp[2] and period='2026-06-01'), 0)
    into v_sum;
  res := res || E'\n' || format('org total equals sum of per-technician figures: %s (org=%s, manual_sum=%s)', v_org_total = v_sum, v_org_total, v_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t7body$;
  v_t8 text := $t8body$
-- Unit 8 — end to end. One month, one organisation, seven technicians:
-- own bike all month, company bike all month, mid-month switch, an excluded
-- month, a top-up, a claim verified lower than submitted, and no expenses at
-- all. Creates its own __TEST_ organisation, master, 7 technicians and a
-- settings row -- never reads from or depends on whatever real data
-- already exists, so this always has exactly the 7 technicians it needs.
-- Rolled-back check — run through the Management API (database/query); it
-- always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_own uuid; v_company uuid; v_switch uuid; v_excluded uuid;
  v_topup uuid; v_lowball uuid; v_none uuid;
  v_own_p uuid; v_company_p uuid; v_switch_p uuid; v_excluded_p uuid;
  v_topup_p uuid; v_lowball_p uuid; v_none_p uuid;
  v_row salaries; v_none_before salaries; v_none_after salaries;
  v_claim public.expense_claims;
  v_base numeric;
  v_org_total numeric; v_manual_sum numeric;
  ids uuid[];
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_monthly_expenses_end_to_end') returning id into v_org;
  insert into settings (org_id) values (v_org);
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'e2e-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('e2e-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;
  ids := v_techp;

  v_own := v_techp[1]; v_company := v_techp[2]; v_switch := v_techp[3]; v_excluded := v_techp[4];
  v_topup := v_techp[5]; v_lowball := v_techp[6]; v_none := v_techp[7];
  v_own_p := v_tech[1]; v_company_p := v_tech[2]; v_switch_p := v_tech[3]; v_excluded_p := v_tech[4];
  v_topup_p := v_tech[5]; v_lowball_p := v_tech[6]; v_none_p := v_tech[7];

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- The no-expenses technician: snapshot salary before touching anything.
  select * into v_none_before from compute_salary(v_org, v_none, '2026-07-01');

  -- Own bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_own, 'own', 3, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_own, '2026-07-10', 40);

  -- Company bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_company, 'company', 0, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_company, '2026-07-10', 40);

  -- Mid-month switch (own 1-15, company 16-31 — a 31-day month)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'own', 2, '2026-07-01', '2026-07-15');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'company', 0, '2026-07-16', '2026-07-31');

  -- Excluded month for the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_excluded_p, 300, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_excluded_p, '2026-07-01', 'recharge', 'exclude', null, 'left mid-month, withheld for July');

  -- Top-up on the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_topup_p, 250, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_topup_p, '2026-07-01', 'recharge', 'top_up', 100, 'extra SIM for the second line this month');

  -- A maintenance claim verified lower than submitted
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_lowball_p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 1000, v_org::text || '/' || v_lowball::text || '/bill.jpg', '2026-07-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform verify_expense_claim(v_claim.id, 650, 'bill included unrelated personal items');

  perform compute_incentives(v_org, '2026-07-01');

  -- Petrol reference figures are informational (km*rate, Fix 5): neither
  -- technician submitted a petrol claim this month, so petrol_amount (what
  -- is actually paid) is correctly 0 for both regardless of their reference
  -- figure — owner revision: the verified claim pays, not km*rate.
  select * into v_row from compute_salary(v_org, v_own, '2026-07-01');
  res := res || E'\n' || format(
    'own-all-month: petrol_reference=%s (expect 120) petrol_amount=%s (expect 0, no claim submitted) bike_allowance_amount=%s (expect base=%s)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount, v_base
  );

  select * into v_row from compute_salary(v_org, v_company, '2026-07-01');
  res := res || E'\n' || format(
    'company-all-month: petrol_reference=%s (expect 0, rate is 0) petrol_amount=%s (expect 0) bike_allowance_amount=%s (expect 0)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount
  );

  select * into v_row from compute_salary(v_org, v_switch, '2026-07-01');
  res := res || E'\n' || format('mid-month-switch: bike_allowance_amount=%s (expect round(%s*15/31,2)=%s)', v_row.bike_allowance_amount, v_base, round(v_base * 15 / 31, 2));

  select * into v_row from compute_salary(v_org, v_excluded, '2026-07-01');
  res := res || E'\n' || format('excluded-month: recharge_amount=%s (expect 0, not 300)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_topup, '2026-07-01');
  res := res || E'\n' || format('top-up: recharge_amount=%s (expect 250+100=350)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_lowball, '2026-07-01');
  res := res || E'\n' || format('verified-lower: maintenance_amount=%s (expect 650, not 1000)', v_row.maintenance_amount);

  -- The technician with no expenses at all is entirely unaffected
  select * into v_none_after from compute_salary(v_org, v_none, '2026-07-01');
  res := res || E'\n' || format(
    'no-expenses technician unaffected: recharge=%s petrol=%s maintenance=%s bike_extra=%s, net unchanged=%s',
    v_none_after.recharge_amount, v_none_after.petrol_amount, v_none_after.maintenance_amount, v_none_after.bike_allowance_extra,
    v_none_before.net = v_none_after.net
  );

  -- Monthly report invariant: org total (these 7) equals the sum of the
  -- per-technician figures.
  select sum(recharge_amount + petrol_amount + maintenance_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-07-01' and technician_id = any(ids);
  select sum(s.recharge_amount + s.petrol_amount + s.maintenance_amount) into v_manual_sum
    from (select recharge_amount, petrol_amount, maintenance_amount from salaries where technician_id = any(ids) and period = '2026-07-01') s;
  res := res || E'\n' || format('org total reconciles with per-technician sum: %s', v_org_total = v_manual_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t8body$;
  v_t9 text := $t9body$
-- ACL guard, CASE13 pattern (from feat/master-time-slots) -- for every
-- function created or redefined by this branch's migrations
-- (20261107100000 through 20261107100500). Rewritten for this review's ACL
-- audit: compute_incentives, compute_salary, submit_expense_claim,
-- verify_expense_claim, technician_km_log_sum, technician_petrol_
-- reference_amount and technician_approx_distance_km are the seven the
-- frontend calls directly and each has a real caller/org check, so
-- `authenticated` IS expected to have EXECUTE and a real call (with
-- garbage arguments) is expected to fail on business logic, never
-- permission. technician_vehicle_on, technician_own_bike_days,
-- technician_expense_claims_total, person_allowance_on, monthly_
-- adjustment_top_up and monthly_adjustment_excluded are internal-only
-- (called only from inside compute_salary/compute_incentives, which
-- already did the real check) and have NO caller/org check of their own,
-- so `authenticated` is expected to have NO EXECUTE on any of them, and a
-- real call is expected to fail with permission denied specifically.
--
-- The pooler/test connection is `postgres`, the owner of every one of
-- these functions -- ownership does not carry through a role switch
-- (verified empirically), but relying on that implicitly, inside other
-- tests that happen to also exercise these functions, is not the same as
-- asserting it. This file asserts it directly.
--
-- Rolled back by its own final RAISE; nothing persists.
do $t$
declare
  res text := '';
  v_sig text;
  v_call text;
  v_expect_granted boolean;
  procs record;
  recs record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

  for recs in
    select * from (values
      ('technician_vehicle_on(uuid,uuid,date)',              $$select technician_vehicle_on(gen_random_uuid(), gen_random_uuid(), current_date)$$,              false),
      ('technician_own_bike_days(uuid,uuid,date)',           $$select technician_own_bike_days(gen_random_uuid(), gen_random_uuid(), current_date)$$,           false),
      ('technician_km_log_sum(uuid,uuid,date)',              $$select technician_km_log_sum(gen_random_uuid(), gen_random_uuid(), current_date)$$,              true),
      ('technician_petrol_reference_amount(uuid,uuid,date)', $$select technician_petrol_reference_amount(gen_random_uuid(), gen_random_uuid(), current_date)$$, true),
      ('technician_approx_distance_km(uuid,uuid,date)',      $$select technician_approx_distance_km(gen_random_uuid(), gen_random_uuid(), current_date)$$,      true),
      ('submit_expense_claim(uuid,text,numeric,text,date)',  $$select submit_expense_claim(gen_random_uuid(), 'petrol', 1, 'x.jpg', current_date)$$,             true),
      ('verify_expense_claim(uuid,numeric,text)',            $$select verify_expense_claim(gen_random_uuid(), 1, null)$$,                                       true),
      ('technician_expense_claims_total(uuid,uuid,date,text)', $$select technician_expense_claims_total(gen_random_uuid(), gen_random_uuid(), current_date, 'petrol')$$, false),
      ('person_allowance_on(uuid,uuid,date)',                $$select person_allowance_on(gen_random_uuid(), gen_random_uuid(), current_date)$$,                false),
      ('monthly_adjustment_top_up(uuid,uuid,date,text)',     $$select monthly_adjustment_top_up(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$, false),
      ('monthly_adjustment_excluded(uuid,uuid,date,text)',   $$select monthly_adjustment_excluded(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$, false),
      ('compute_incentives(uuid,date)',                      $$select compute_incentives(gen_random_uuid(), current_date)$$,                                    true),
      ('compute_salary(uuid,uuid,date)',                     $$select compute_salary(gen_random_uuid(), gen_random_uuid(), current_date)$$,                     true)
    ) as t(sig, call, expect_granted)
  loop
    v_sig := recs.sig;
    v_call := recs.call;
    v_expect_granted := recs.expect_granted;

    if has_function_privilege('authenticated', format('public.%s', v_sig), 'execute') then
      if not v_expect_granted then
        res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated HAS execute, expected none (internal-only, no caller/org check)';
      else
        execute 'set local role authenticated';
        begin
          execute v_call;
          res := res || E'\n' || 'ok   '||v_sig||' -- granted as expected, call unexpectedly succeeded with garbage args (still proves no permission error)';
        exception when others then
          res := res || E'\n' || case
            when sqlerrm ilike '%permission denied%' then 'FAIL '||v_sig||' -- granted, but hit permission denied anyway: '||sqlerrm
            else 'ok   '||v_sig||' -- granted as expected, failed on business logic not permission: '||sqlerrm
          end;
        end;
        execute 'reset role';
      end if;
    else
      if v_expect_granted then
        res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated has NO execute, expected a grant (frontend calls this directly)';
      else
        execute 'set local role authenticated';
        begin
          execute v_call;
          res := res || E'\n' || 'FAIL '||v_sig||' -- not granted, but the call SUCCEEDED anyway (grant check bypassed somehow)';
        exception when others then
          res := res || E'\n' || case
            when sqlerrm ilike '%permission denied%' then 'ok   '||v_sig||' -- correctly ungranted: '||sqlerrm
            else 'FAIL '||v_sig||' -- ungranted but failed on something other than permission denied: '||sqlerrm
          end;
        end;
        execute 'reset role';
      end if;
    end if;
  end loop;

  raise exception E'RESULTS:%', res;
end
$t$;
$t9body$;
  v_old_incentives text := $oldincbody$
create or replace function public.compute_incentives(p_org_id uuid, p_period date)
 RETURNS SETOF incentives_earned
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
  v_review_enabled boolean;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  -- Google's policy forbids rewarding reviews: the 'review' rule type only pays while the master has switched this ON
  -- (default OFF). Existing rules and rows are untouched; the switch only stops new computations.
  select coalesce(s.review_incentives_enabled, false) into v_review_enabled from public.settings s where s.org_id = p_org_id;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id and is_active loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      -- A rule set to ₹0 pays nothing: no zero-amount rows.
      if v_rule.amount <= 0 then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' and v_review_enabled then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and not public._visit_is_test(v.id)
          and r.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and r.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'installation' then
        v_metric := public.technician_installation_count(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  -- Per-unit installation rates (additive to the flat-threshold rule above).
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    for v_rate in
      select m.rate_id, sum(m.qty)::int as qty, ra.flat_amount
      from (
        select il.qty, public.installation_rate_for(p_org_id, il.product_id) as rate_id
        from public.installations_logged il
        where il.org_id = p_org_id
          and il.technician_id = v_tech.id
          -- already paid by an installation-ticket credit (pending or approved): never counted twice
          and not exists (
            select 1 from public.installation_incentive_credits c
            where c.visit_id = il.visit_id and c.product_id = il.product_id and c.status <> 'void'
          )
          and not public._visit_is_test(il.visit_id)
          and il.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and il.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      ) m
      join public.installation_incentive_rates ra on ra.id = m.rate_id
      group by m.rate_id, ra.flat_amount
    loop
      v_amount := v_rate.qty * v_rate.flat_amount;
      if v_amount <= 0 then
        continue;
      end if;
      select id into v_existing_id from public.incentives_earned
        where technician_id = v_tech.id and installation_rate_id = v_rate.rate_id and period = v_period;
      if v_existing_id is null then
        insert into public.incentives_earned (org_id, technician_id, installation_rate_id, amount, period)
        values (p_org_id, v_tech.id, v_rate.rate_id, v_amount, v_period);
      else
        update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
      end if;
    end loop;
  end loop;

  -- Installation-ticket credits: the master-approved credits completed in the month, one row per technician and month.
  -- Recomputed on every run (like the per-unit rates) so a late approval or a void is reflected.
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    select coalesce(sum(c.amount), 0) into v_amount
    from public.installation_incentive_credits c
    where c.org_id = p_org_id
      and c.technician_id = v_tech.id
      and c.status = 'approved'
      and c.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
      and c.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      and not public._ticket_is_test(c.ticket_id);
    select id into v_existing_id from public.incentives_earned
      where technician_id = v_tech.id and credit_source = 'installation_ticket' and period = v_period;
    if v_existing_id is null then
      if v_amount > 0 then
        insert into public.incentives_earned (org_id, technician_id, credit_source, amount, period)
        values (p_org_id, v_tech.id, 'installation_ticket', v_amount, v_period);
      end if;
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;
$oldincbody$;
  v_old_salary text := $oldsalbody$
create or replace function public.compute_salary(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns salaries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_base numeric(12, 2);
  v_revenue numeric(12, 2);
  v_late_hours numeric(12, 2);
  v_late_deduction numeric(12, 2);
  v_incentives numeric(12, 2);
  v_row salaries;
begin
  if not public.is_master() then
    raise exception 'compute_salary: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_salary: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = p_org_id) then
    raise exception 'compute_salary: technician % not found in org %', p_technician_id, p_org_id;
  end if;

  select tt.monthly_salary into v_base
  from public.technicians t
  join public.technician_tiers tt on tt.id = t.tier_id
  where t.id = p_technician_id;
  if v_base is null then
    select tt.monthly_salary into v_base
    from public.technician_tiers tt
    where tt.org_id = p_org_id and tt.rank = 1;
  end if;
  v_base := coalesce(v_base, 0);

  v_revenue := public.technician_attributed_revenue(p_org_id, p_technician_id, v_period);
  v_late_hours := public.technician_late_hours(p_org_id, p_technician_id, v_period);
  -- v2.2: "late deduction hours x 2" — see original definition.
  v_late_deduction := round(v_late_hours * 2, 2);

  select coalesce(sum(amount), 0) into v_incentives
  from public.incentives_earned
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  insert into public.salaries (org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net)
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives,
    v_base + v_revenue - v_late_deduction + v_incentives
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net
  returning * into v_row;

  return v_row;
end;
$$;
$oldsalbody$;
  v_m1_expected_sha256 text := '13586709047ccc74cc36b63337b4178e6bd98637378a38105722d30383d4d32a';
  v_m2_expected_sha256 text := '4b2c5f0a450d770b609f74d78ac9ad6d18392727ee2f4b11e3f5180e481d3ca8';
  v_m3_expected_sha256 text := 'b3ac30147f8ab59d5d47c229f69b7e4ac1c55022a5c58baa6ba8ee02161f3aa1';
  v_m4_expected_sha256 text := '2149569063c4babd9be5989e9287ebe565a753222215ba807d44550944792a05';
  v_m5_expected_sha256 text := '1fc60b3e25429d63d252f71d2d4a536cd352264ce1c87060d30cbd53c9732b45';
  v_m6_expected_sha256 text := 'bcaeedaad27c6d99217b9300a53619ad41beba9a218aac694b40184b1de7acf8';
  v_old_inc_expected_sha256 text := '7abcd18ab1ccfb5ac753691a625d9c18108593b5aa56626c9b0b5806ee8d1c22';
  v_old_sal_expected_sha256 text := '01a84dda4fce7e768f7dc631d4526bc8f74d8557be84be5ebf84f7a364189bd6';
  v_t1_expected_sha256 text := '0da2f193dc87b521e3bc97943ecd976612782bbfddbf7a91c660ad96f52ccee0';
  v_t2_expected_sha256 text := '45b91836daaa988d2f0569ad6fbee6e141a4389d65455219262cdb7d802d069c';
  v_t3_expected_sha256 text := 'c84cf98e04b559535ec0ce28b60da4aa359cf9176c68f7b0dcab36821fd01236';
  v_t4_expected_sha256 text := '72784f9daa7810b0e689f1070f1f321468f2c09c195d0f0e81464e1995c31767';
  v_t5_expected_sha256 text := '258b5f0c439e04534c6bab4b41e0d7c24a0ba07567f2e50fdb8a97be2d77a839';
  v_t6_expected_sha256 text := '48a6e3006c685d9c4b2518450f43ca54fbaa7173db2f13d936f04cfd330475e4';
  v_t7_expected_sha256 text := 'f9792748a7750170e5d35acf3a762cf10693447479507427c0acd21d155f013c';
  v_t8_expected_sha256 text := '73fd0c0cc4b451e772d06fad5ac4c4b18e3320d3eb5e55ce5283842fabd26954';
  v_t9_expected_sha256 text := 'c3ef17ced16b34ed1f3d6e5be98e180b18a40d4202263d580565ad5107773bf5';
begin
  -- lock budget -- first executed statement, before even the time gate, so a real run can
  -- never hang on contention (standard form across every other package's wrapper this
  -- release). Added by the release gate-fix review; was previously missing entirely.
  perform set_config('lock_timeout', '5s', true);

  if v_now_ist < '11:00:00'::time then
    raise exception 'rehearsal refused: run after 11:00 IST, current IST wall-clock time is %', v_now_ist;
  end if;

  -- Strip the single leading newline that Postgres's dollar-quoting includes whenever the
  -- opening tag ($mNbody$/$tNbody$/$oldincbody$/$oldsalbody$) is on its own line and the
  -- embedded text starts on the next line (true for every one of the 17 blocks below). Each
  -- pin below is computed against the clean, on-disk file (no leading newline) -- without
  -- this strip every single sha256 check fails (confirmed live: migration 1 came back as
  -- 7769 bytes instead of the real file's 7768). This wrapper had never actually been run
  -- against a live DB before; found during this release's Phase 1 rehearsal. Only ever
  -- strips exactly one leading '\n', never more.
  v_m1 := regexp_replace(v_m1, '^\n', '');
  v_m2 := regexp_replace(v_m2, '^\n', '');
  v_m3 := regexp_replace(v_m3, '^\n', '');
  v_m4 := regexp_replace(v_m4, '^\n', '');
  v_m5 := regexp_replace(v_m5, '^\n', '');
  v_m6 := regexp_replace(v_m6, '^\n', '');
  v_t1 := regexp_replace(v_t1, '^\n', '');
  v_t2 := regexp_replace(v_t2, '^\n', '');
  v_t3 := regexp_replace(v_t3, '^\n', '');
  v_t4 := regexp_replace(v_t4, '^\n', '');
  v_t5 := regexp_replace(v_t5, '^\n', '');
  v_t6 := regexp_replace(v_t6, '^\n', '');
  v_t7 := regexp_replace(v_t7, '^\n', '');
  v_t8 := regexp_replace(v_t8, '^\n', '');
  v_t9 := regexp_replace(v_t9, '^\n', '');
  v_old_incentives := regexp_replace(v_old_incentives, '^\n', '');
  v_old_salary := regexp_replace(v_old_salary, '^\n', '');

  v_actual_sha256 := encode(sha256(convert_to(v_m1, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m1_expected_sha256 then
    raise exception 'rehearsal refused: migration 1 (technician_vehicles) text does not match its pinned sha256 (expected %, got %)', v_m1_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_m2, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m2_expected_sha256 then
    raise exception 'rehearsal refused: migration 2 (technician_km_log) text does not match its pinned sha256 (expected %, got %)', v_m2_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_m3, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m3_expected_sha256 then
    raise exception 'rehearsal refused: migration 3 (expense_claims) text does not match its pinned sha256 (expected %, got %)', v_m3_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_m4, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m4_expected_sha256 then
    raise exception 'rehearsal refused: migration 4 (person_allowances_and_adjustments) text does not match its pinned sha256 (expected %, got %)', v_m4_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_m5, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m5_expected_sha256 then
    raise exception 'rehearsal refused: migration 5 (compute_incentives_bike_allowance) text does not match its pinned sha256 (expected %, got %)', v_m5_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_m6, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_m6_expected_sha256 then
    raise exception 'rehearsal refused: migration 6 (compute_salary_itemised_expenses) text does not match its pinned sha256 (expected %, got %)', v_m6_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_old_incentives, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_old_inc_expected_sha256 then
    raise exception 'rehearsal refused: embedded ORIGINAL compute_incentives text does not match its pinned sha256 (expected %, got %) -- this wrapper''s claim about the live body is stale', v_old_inc_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_old_salary, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_old_sal_expected_sha256 then
    raise exception 'rehearsal refused: embedded ORIGINAL compute_salary text does not match its pinned sha256 (expected %, got %) -- this wrapper''s claim about the live body is stale', v_old_sal_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || 'all 8 embedded texts (6 migrations + 2 original function bodies) sha256-verified via encode(sha256(convert_to(text, ''UTF8'')), ''hex'')';

  v_actual_sha256 := encode(sha256(convert_to(v_t1, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t1_expected_sha256 then
    raise exception 'rehearsal refused: test 1 (technician_vehicles.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t1_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t2, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t2_expected_sha256 then
    raise exception 'rehearsal refused: test 2 (technician_km_log.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t2_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t3, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t3_expected_sha256 then
    raise exception 'rehearsal refused: test 3 (expense_claims.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t3_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t4, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t4_expected_sha256 then
    raise exception 'rehearsal refused: test 4 (person_allowances_and_adjustments.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t4_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t5, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t5_expected_sha256 then
    raise exception 'rehearsal refused: test 5 (compute_incentives_bike_allowance.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t5_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t6, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t6_expected_sha256 then
    raise exception 'rehearsal refused: test 6 (compute_salary_itemised_expenses.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t6_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t7, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t7_expected_sha256 then
    raise exception 'rehearsal refused: test 7 (monthly_expenses_report.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t7_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t8, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t8_expected_sha256 then
    raise exception 'rehearsal refused: test 8 (monthly_expenses_end_to_end.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t8_expected_sha256, v_actual_sha256;
  end if;
  v_actual_sha256 := encode(sha256(convert_to(v_t9, 'UTF8')), 'hex');
  if v_actual_sha256 is distinct from v_t9_expected_sha256 then
    raise exception 'rehearsal refused: test 9 (acl_guard_monthly_expenses.test.sql) text does not match its pinned sha256 (expected %, got %)', v_t9_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || 'all 9 embedded tests sha256-verified';

  select count(*) into v_org_count from organizations where name not ilike '\_\_TEST%';
  if v_org_count <> 1 then
    raise exception 'rehearsal refused: expected exactly 1 real organisation, found %', v_org_count;
  end if;
  select id into v_org from organizations where name not ilike '\_\_TEST%' limit 1;

  -- ── Fingerprint BEFORE migration 1 runs: real organisation's salaries, ──
  -- incentives_earned AND settings (settings with the not-yet-existing
  -- own_bike_allowance_base key removed via jsonb `-`, a no-op before
  -- migration 4 adds it -- same expression used for the after-fingerprint
  -- below, so both sides are computed identically).
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_before;
  res := res || E'\n' || format('fingerprint before migration 1: %s', v_fp_before);

  -- ── Pre-check 1 of 2, BEFORE migration 1 (hence trivially before 5 and ──
  -- 6): prove the embedded ORIGINAL compute_incentives text really is the
  -- live body.
  select md5(pg_get_functiondef('public.compute_incentives(uuid,date)'::regprocedure)) into v_live_inc_md5;
  begin
    execute v_old_incentives;
    select md5(pg_get_functiondef('public.compute_incentives(uuid,date)'::regprocedure)) into v_recreated_inc_md5;
    raise exception 'SUBBLOCK_DONE_ROLLBACK';
  exception when others then
    if sqlerrm <> 'SUBBLOCK_DONE_ROLLBACK' then
      raise;
    end if;
  end;
  if v_recreated_inc_md5 is distinct from v_live_inc_md5 then
    raise exception 'rehearsal refused: recreating the embedded ORIGINAL compute_incentives body does not reproduce the live function (live md5=%, recreated md5=%) -- the live function has drifted since this wrapper was written', v_live_inc_md5, v_recreated_inc_md5;
  end if;
  res := res || E'\n' || format('pre-check 1/2 verified and rolled back, before migration 1 ran: recreating the original compute_incentives body reproduces the live function exactly (md5 %s)', v_live_inc_md5);

  -- ── Pre-check 2 of 2, same timing: prove the embedded ORIGINAL ──────────
  -- compute_salary text really is the live body.
  select md5(pg_get_functiondef('public.compute_salary(uuid,uuid,date)'::regprocedure)) into v_live_sal_md5;
  begin
    execute v_old_salary;
    select md5(pg_get_functiondef('public.compute_salary(uuid,uuid,date)'::regprocedure)) into v_recreated_sal_md5;
    raise exception 'SUBBLOCK_DONE_ROLLBACK';
  exception when others then
    if sqlerrm <> 'SUBBLOCK_DONE_ROLLBACK' then
      raise;
    end if;
  end;
  if v_recreated_sal_md5 is distinct from v_live_sal_md5 then
    raise exception 'rehearsal refused: recreating the embedded ORIGINAL compute_salary body does not reproduce the live function (live md5=%, recreated md5=%) -- the live function has drifted since this wrapper was written', v_live_sal_md5, v_recreated_sal_md5;
  end if;
  res := res || E'\n' || format('pre-check 2/2 verified and rolled back, before migration 1 ran: recreating the original compute_salary body reproduces the live function exactly (md5 %s)', v_live_sal_md5);

  execute v_m1;
  execute v_m2;
  execute v_m3;
  execute v_m4;
  execute v_m5;
  execute v_m6;
  res := res || E'\n' || 'all six migrations executed, in order (20261107100000 through 20261107100500)';

  -- ── Fingerprint immediately after migration 6, BEFORE any recompute or ──
  -- test: must be IDENTICAL to the before-migration-1 fingerprint. True by
  -- construction -- migrations 1-6 only add tables/columns/functions, and
  -- nothing between the two fingerprints has called compute_incentives or
  -- compute_salary, so no existing salaries/incentives_earned row (or
  -- settings' pre-existing columns) can have changed.
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_after_migrations;
  if v_fp_after_migrations is distinct from v_fp_before then
    raise exception 'rehearsal refused: fingerprint changed by the six migrations alone, before any recompute or test ran (before=%, after=%) -- this should be impossible for a pure schema/function change', v_fp_before, v_fp_after_migrations;
  end if;
  res := res || E'\n' || format('fingerprint immediately after migration 6, before any recompute or test (expect identical to before): %s -- identical: true', v_fp_after_migrations);

  begin
    execute v_t1;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== technician_vehicles.test.sql ===' || v_test_result;

  begin
    execute v_t2;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== technician_km_log.test.sql ===' || v_test_result;

  begin
    execute v_t3;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== expense_claims.test.sql ===' || v_test_result;

  begin
    execute v_t4;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== person_allowances_and_adjustments.test.sql ===' || v_test_result;

  begin
    execute v_t5;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== compute_incentives_bike_allowance.test.sql ===' || v_test_result;

  begin
    execute v_t6;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== compute_salary_itemised_expenses.test.sql ===' || v_test_result;

  begin
    execute v_t7;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== monthly_expenses_report.test.sql ===' || v_test_result;

  begin
    execute v_t8;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== monthly_expenses_end_to_end.test.sql ===' || v_test_result;

  begin
    execute v_t9;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== acl_guard_monthly_expenses.test.sql ===' || v_test_result;

  -- ── Control comparison: "a technician with no expenses is paid the ──────
  -- same" -- run entirely in its own throwaway __TEST_ organisation (its
  -- own technician, settings row and one incentive_rule), never against
  -- real technicians.
  insert into organizations (name) values ('__TEST_no_expense_control') returning id into v_ctrl_org;
  insert into settings (org_id) values (v_ctrl_org);
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'ctrl-master@test.invalid')
    returning id into v_ctrl_master;
  insert into profiles (id, org_id, full_name, role) values (v_ctrl_master, v_ctrl_org, '__TEST_ control master', 'master');
  v_ctrl_tech := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_ctrl_tech, 'authenticated', 'authenticated', 'ctrl-tech@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_ctrl_tech, v_ctrl_org, '__TEST_ control tech', 'technician');
  insert into technicians (org_id, profile_id) values (v_ctrl_org, v_ctrl_tech) returning id into v_ctrl_techp;
  insert into incentive_rules (org_id, type, threshold, amount) values (v_ctrl_org, 'service_income', 0, 100)
    returning id into v_ctrl_rule_id;

  -- A fixed, pre-existing incentive, inserted directly rather than relying
  -- on the rule above to fire: compute_incentives' own rule loop requires
  -- `v_rule.threshold > 0` before it ever inserts anything for service_
  -- income/sales_income/finder_credit/installation rule types, so a
  -- threshold-0 rule, by design, NEVER pays -- it would give a trivial
  -- zero-equals-zero comparison, not a real one. This row simulates an
  -- incentive from some OTHER already-existing source, giving the control
  -- technician a genuinely nonzero figure to compare. Inserted BEFORE the
  -- nested sub-block below so it survives that sub-block's rollback and
  -- is visible to both the old-body and new-body calls.
  insert into incentives_earned (org_id, technician_id, rule_id, amount, period)
    values (v_ctrl_org, v_ctrl_techp, v_ctrl_rule_id, 100, v_ctrl_period);

  -- Recreate both OLD bodies as the OWNER (no role set) -- CREATE OR
  -- REPLACE FUNCTION requires ownership, which `authenticated` does not
  -- have, so this must run BEFORE any role switch, never after one. Only
  -- the compute_* calls run as authenticated; role is reset immediately
  -- after them and again, defensively, in the exception handler, before
  -- anything else happens (including the next replacement, once this
  -- sub-block's rollback restores the NEW bodies).
  begin
    execute v_old_incentives;
    execute v_old_salary;

    perform set_config('request.jwt.claims', json_build_object('sub', v_ctrl_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform compute_incentives(v_ctrl_org, v_ctrl_period);
    select coalesce(jsonb_agg(jsonb_build_object('rule_id', rule_id, 'installation_rate_id', installation_rate_id, 'credit_source', credit_source, 'amount', amount) order by rule_id, installation_rate_id, credit_source), '[]'::jsonb)
      into v_old_incentives_baseline
      from incentives_earned where org_id = v_ctrl_org and technician_id = v_ctrl_techp and period = v_ctrl_period;
    perform compute_salary(v_ctrl_org, v_ctrl_techp, v_ctrl_period);
    select * into v_old_salary_baseline from salaries where org_id = v_ctrl_org and technician_id = v_ctrl_techp and period = v_ctrl_period;
    execute 'reset role';

    raise exception 'SUBBLOCK_DONE_ROLLBACK';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'SUBBLOCK_DONE_ROLLBACK' then
      raise;
    end if;
  end;
  res := res || E'\n\n' || format('control technician %s, period %s, baseline under the recreated-then-rolled-back OLD bodies -- incentives=%s base=%s revenue=%s late_deduction=%s incentives_component=%s net=%s',
    v_ctrl_techp, v_ctrl_period, v_old_incentives_baseline, v_old_salary_baseline.base, v_old_salary_baseline.revenue_component, v_old_salary_baseline.late_deduction, v_old_salary_baseline.incentives, v_old_salary_baseline.net);

  -- Guard against a vacuous pass: compute_incentives never deletes or
  -- truncates incentives_earned anywhere (confirmed by inspection -- the
  -- rule loop's existence check is skip-only, `continue`, never a
  -- delete), so the fixed row inserted above should survive untouched.
  -- Refuse rather than silently compare zero-to-zero if that assumption
  -- is ever wrong.
  if v_old_salary_baseline.incentives <= 0 or jsonb_array_length(v_old_incentives_baseline) = 0 then
    raise exception 'rehearsal refused: control technician''s OLD-body incentives baseline is not > 0 (incentives_earned=%, salaries.incentives=%) -- the fixed seeded row appears to have been altered or removed, which would make the OLD-vs-NEW comparison below vacuous (0 = 0)', v_old_incentives_baseline, v_old_salary_baseline.incentives;
  end if;
  res := res || E'\n' || format('baseline sanity check passed: OLD-body incentives_component=%s (> 0) and net reflects it', v_old_salary_baseline.incentives);

  -- NEW bodies are restored (the sub-block above rolled its recreate
  -- back). Same discipline: switch to authenticated only for the
  -- compute_* calls, reset immediately after.
  perform set_config('request.jwt.claims', json_build_object('sub', v_ctrl_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform compute_incentives(v_ctrl_org, v_ctrl_period);
  select coalesce(jsonb_agg(jsonb_build_object('rule_id', rule_id, 'installation_rate_id', installation_rate_id, 'credit_source', credit_source, 'amount', amount) order by rule_id, installation_rate_id, credit_source), '[]'::jsonb)
    into v_new_incentives_check
    from incentives_earned where org_id = v_ctrl_org and technician_id = v_ctrl_techp and period = v_ctrl_period and not is_bike_allowance;
  perform compute_salary(v_ctrl_org, v_ctrl_techp, v_ctrl_period);
  select * into v_new_salary_check from salaries where org_id = v_ctrl_org and technician_id = v_ctrl_techp and period = v_ctrl_period;
  execute 'reset role';

  res := res || E'\n' || format('same control technician under the NEW bodies -- non-bike-allowance incentives=%s | base=%s revenue=%s late_deduction=%s incentives_component=%s net=%s',
    v_new_incentives_check, v_new_salary_check.base, v_new_salary_check.revenue_component, v_new_salary_check.late_deduction, v_new_salary_check.incentives, v_new_salary_check.net);

  -- Same vacuous-pass guard, mirrored on the NEW side.
  if v_new_salary_check.incentives <= 0 or jsonb_array_length(v_new_incentives_check) = 0 then
    raise exception 'rehearsal refused: control technician''s NEW-body incentives check is not > 0 (incentives_earned=%, salaries.incentives=%) -- the fixed seeded row appears to have been altered or removed under the new function', v_new_incentives_check, v_new_salary_check.incentives;
  end if;

  res := res || E'\n' || format('incentives equal, OLD body vs NEW body (expect true): %s (old=%s new=%s)', v_old_incentives_baseline = v_new_incentives_check, v_old_incentives_baseline, v_new_incentives_check);
  res := res || E'\n' || format('net equal, OLD body vs NEW body (expect true): %s (old=%s new=%s)', v_old_salary_baseline.net = v_new_salary_check.net, v_old_salary_baseline.net, v_new_salary_check.net);
  res := res || E'\n' || format('every other salary component also equal (expect true): %s',
    v_old_salary_baseline.base = v_new_salary_check.base
    and v_old_salary_baseline.revenue_component = v_new_salary_check.revenue_component
    and v_old_salary_baseline.late_deduction = v_new_salary_check.late_deduction
    and v_old_salary_baseline.incentives = v_new_salary_check.incentives);

  -- Final fingerprint of the real organisation, after everything above --
  -- all nine tests and the whole control comparison (which only ever
  -- touched the throwaway __TEST_no_expense_control org). Same expression
  -- as v_fp_before/v_fp_after_migrations: must still be identical, since
  -- nothing in this rehearsal ever recomputed or wrote against the real
  -- org's technicians.
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_final;
  if v_fp_final is distinct from v_fp_before then
    raise exception 'rehearsal refused: CHANGED -- final fingerprint of the real organisation differs from before-migration-1 (before=%, final=%) -- something in this rehearsal touched real data', v_fp_before, v_fp_final;
  end if;
  res := res || E'\n' || format('final fingerprint of the real organisation, after all nine tests and the control comparison (expect identical to before): %s -- identical: true', v_fp_final);

  raise exception E'RESULTS%', res;
end
$combo$;
