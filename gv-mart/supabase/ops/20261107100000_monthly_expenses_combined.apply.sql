-- GO APPLY script for 6 chained migrations: 20261107100000 through 20261107100500
-- (Monthly Expenses: technician_vehicles, technician_km_log, expense_claims,
-- person_allowances_and_adjustments, compute_incentives bike-allowance branch,
-- compute_salary itemised-expenses branch), on feat/monthly-expenses-v2.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- (standing hard rule: no DB access of any kind). The owner runs this by hand, after 11:00
-- IST, once satisfied the sha256-pinned migration texts embedded below are byte-for-byte the
-- reviewed migration files, and that the live rehearsal
-- (supabase/ops/rehearsals/rehearse_combined_all_units.sql) came back clean (it did: 8/8
-- embedded-file pins OK, 2/2 live-def pre-checks OK, all 6 migrations applied+rolled back,
-- 9/9 tests 0 failures, real-org fingerprint unchanged).
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit
-- is already atomic -- all 6 migrations, the registration of all 6 versions, and every check
-- either all commit together or (on any RAISE) all roll back together. Three statements:
-- (1) CREATE TEMP TABLE for the status row, autocommitted on its own; (2) the DO block;
-- (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS SCRIPT IS
-- MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE on existing rows. All 6 migrations only add new tables/columns and
-- redefine 2 EXISTING functions (compute_incentives, compute_salary) -- confirmed by the
-- rehearsal's own live-definition pre-check, re-confirmed here with the same mechanism.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must
--      equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST.
--   3. ALREADY-REGISTERED CHECK -- refuses if ANY of the 6 versions is already registered
--      (chained migrations must all apply together or not at all).
--   4. LIVE-DEFINITION PRE-CHECK -- pg_get_functiondef of the live compute_incentives and
--      compute_salary, normalised (schema-qualified name -> 'FN'), must match the pinned
--      ORIGINAL bodies below -- refuses to redefine either blindly if live has drifted.
--   5. REAL-ORG FINGERPRINT (BEFORE) -- the single real organisation's salaries/
--      incentives_earned/settings, same formula the rehearsal uses.
--   6. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by
--      PUBLIC/anon.
--   7. PIN          -- CR-tolerant sha256 of each of the 6 embedded migration texts must
--      equal its pinned LF hash.
--   8. RUN          -- EXECUTE all 6 pinned migration texts verbatim, in order (CR-tolerant).
--   9. REGISTER     -- INSERT all 6 version rows into supabase_migrations.schema_migrations,
--      in the same transaction as the migrations themselves.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. compute_incentives and compute_salary still exist and are not executable by
--          anon/PUBLIC;
--      10b. the 4 strictly-internal functions this feature relies on
--          (technician_vehicle_on, technician_own_bike_days, technician_expense_claims_total,
--          person_allowance_on, monthly_adjustment_top_up, monthly_adjustment_excluded) --
--          none of them is executable by anon/PUBLIC either (matches the rehearsal's ACL
--          guard test);
--      10c. DIFF-BASED leak check against the BEFORE snapshot (step 6) -- only NEWLY exposed
--          functions fail this check;
--      10d. the real organisation's fingerprint (step 5) is unchanged -- none of these
--          migrations backfills or touches an existing salaries/incentives_earned/settings
--          row.
--   11. On success, INSERT the one status row into pg_temp.monthly_expenses_apply_status.
--
-- No test file is embedded and there is no rollback invoked here: any rollback is run by hand,
-- separately, only if the owner decides to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.monthly_expenses_apply_status;
create temp table monthly_expenses_apply_status (
  versions_registered           text[],
  functions_exist                boolean,
  functions_not_anon_executable  boolean,
  internal_functions_not_anon_executable boolean,
  newly_leaked_functions         text[],
  org_fingerprint_before         text,
  org_fingerprint_after          text,
  real_org_fp_before             text,
  real_org_fp_after              text,
  applied_at                     timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_org                      uuid;
  v_already_registered       boolean;
  v_live_inc_def              text;
  v_live_sal_def              text;
  v_pin_inc_def                text;
  v_pin_sal_def                text;
  v_real_fp_before             text;
  v_real_fp_after              text;
  v_leaked_before              text[];
  v_leaked_after               text[];
  v_newly_leaked               text[];
  v_anon_exec                  boolean := false;
  v_internal_anon_exec         boolean := false;
  v_actual_hash                text;
  v_m1_mig        text := $m1body_x$-- Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md), Unit 1 — bike
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
$m1body_x$;
  v_m2_mig        text := $m2body_x$-- Monthly Expenses spec, Unit 2 — kilometre log (§1.5/§3.2). Append-only: no
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
$m2body_x$;
  v_m3_mig        text := $m3body_x$-- Monthly Expenses spec, Unit 3 — petrol/maintenance bill submission and
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
$m3body_x$;
  v_m4_mig        text := $m4body_x$-- Monthly Expenses spec, Unit 4 — recharge allowances, the generic
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
$m4body_x$;
  v_m5_mig        text := $m5body_x$-- Monthly Expenses spec, Unit 5 — own-bike allowance flows into
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
$m5body_x$;
  v_m6_mig        text := $m6body_x$-- Monthly Expenses spec, Unit 6 — four itemised lines in compute_salary
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
$m6body_x$;
  v_old_incentives            text := $oldinc_x$create or replace function public.compute_incentives(p_org_id uuid, p_period date)
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
$oldinc_x$;
  v_old_salary                 text := $oldsal_x$create or replace function public.compute_salary(
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
$oldsal_x$;
begin
  -- 0. ORG CHECK
  select o.id, md5(o.id::text || '|' || o.name) into v_org, v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK -- any of the 6.
  select exists(
    select 1 from supabase_migrations.schema_migrations
    where version in ('20261107100000','20261107100100','20261107100200','20261107100300','20261107100400','20261107100500')
  ) into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: one or more of the 6 monthly-expenses migration versions is already registered -- stop, nothing applied';
  end if;

  -- 4. LIVE-DEFINITION PRE-CHECK -- compute_incentives, compute_salary.
  -- PIN the two embedded ORIGINAL bodies first (previously missing: this script pinned only
  -- the 6 migration texts, never these two -- fixed here, hashes re-verified against the
  -- rehearsal's own v_old_inc_expected_sha256/v_old_sal_expected_sha256).
  v_actual_hash := encode(sha256(convert_to(replace(v_old_incentives, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '7abcd18ab1ccfb5ac753691a625d9c18108593b5aa56626c9b0b5806ee8d1c22' then
    raise exception 'APPLY_REFUSED: embedded ORIGINAL compute_incentives text does not match its pinned sha256 (expected 7abcd18ab1ccfb5ac753691a625d9c18108593b5aa56626c9b0b5806ee8d1c22, got %)', v_actual_hash;
  end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_old_salary, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '01a84dda4fce7e768f7dc631d4526bc8f74d8557be84be5ebf84f7a364189bd6' then
    raise exception 'APPLY_REFUSED: embedded ORIGINAL compute_salary text does not match its pinned sha256 (expected 01a84dda4fce7e768f7dc631d4526bc8f74d8557be84be5ebf84f7a364189bd6, got %)', v_actual_hash;
  end if;

  -- GV_PRECHECK_PROBE pattern (matches rehearse_combined_all_units.sql lines 2923-2949 exactly):
  -- hash the REAL live public.compute_incentives/public.compute_salary, then inside a sub-block
  -- that is always rolled back via a deliberate sentinel exception, apply the pinned ORIGINAL
  -- text to that SAME real function and hash it again -- compare. (Previous revision of this
  -- check cast 'pg_temp.compute_incentives(...)'::regprocedure, a function that is never
  -- created anywhere in this script -- that cast would unconditionally raise
  -- "function pg_temp.compute_incentives(uuid, date) does not exist" before RUN was ever
  -- reached. Fixed to operate on public.compute_incentives/public.compute_salary directly,
  -- the same object before and after the sub-block, exactly as the rehearsal does.)
  v_pin_inc_def := md5(pg_get_functiondef('public.compute_incentives(uuid,date)'::regprocedure));
  begin
    execute replace(v_old_incentives, E'\r', '');
    v_live_inc_def := md5(pg_get_functiondef('public.compute_incentives(uuid,date)'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_live_inc_def is distinct from v_pin_inc_def then
    raise exception 'APPLY_REFUSED: live compute_incentives no longer matches the pinned ORIGINAL body -- refusing to redefine it blindly';
  end if;

  v_pin_sal_def := md5(pg_get_functiondef('public.compute_salary(uuid,uuid,date)'::regprocedure));
  begin
    execute replace(v_old_salary, E'\r', '');
    v_live_sal_def := md5(pg_get_functiondef('public.compute_salary(uuid,uuid,date)'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_live_sal_def is distinct from v_pin_sal_def then
    raise exception 'APPLY_REFUSED: live compute_salary no longer matches the pinned ORIGINAL body -- refusing to redefine it blindly';
  end if;

  -- 5. REAL-ORG FINGERPRINT (BEFORE) -- same formula the rehearsal uses, for the single real org.
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_real_fp_before;

  -- 6. LEAK SNAPSHOT (BEFORE)
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 20261107100000 (technician_vehicles)
  v_actual_hash := encode(sha256(convert_to(replace(v_m1_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '13586709047ccc74cc36b63337b4178e6bd98637378a38105722d30383d4d32a' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100000 (technician_vehicles) text does not match its pinned sha256 (expected 13586709047ccc74cc36b63337b4178e6bd98637378a38105722d30383d4d32a, got %)', v_actual_hash;
  end if;

  -- 20261107100100 (technician_km_log)
  v_actual_hash := encode(sha256(convert_to(replace(v_m2_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '4b2c5f0a450d770b609f74d78ac9ad6d18392727ee2f4b11e3f5180e481d3ca8' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100100 (technician_km_log) text does not match its pinned sha256 (expected 4b2c5f0a450d770b609f74d78ac9ad6d18392727ee2f4b11e3f5180e481d3ca8, got %)', v_actual_hash;
  end if;

  -- 20261107100200 (expense_claims)
  v_actual_hash := encode(sha256(convert_to(replace(v_m3_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from 'b3ac30147f8ab59d5d47c229f69b7e4ac1c55022a5c58baa6ba8ee02161f3aa1' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100200 (expense_claims) text does not match its pinned sha256 (expected b3ac30147f8ab59d5d47c229f69b7e4ac1c55022a5c58baa6ba8ee02161f3aa1, got %)', v_actual_hash;
  end if;

  -- 20261107100300 (person_allowances_and_adjustments)
  v_actual_hash := encode(sha256(convert_to(replace(v_m4_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '2149569063c4babd9be5989e9287ebe565a753222215ba807d44550944792a05' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100300 (person_allowances_and_adjustments) text does not match its pinned sha256 (expected 2149569063c4babd9be5989e9287ebe565a753222215ba807d44550944792a05, got %)', v_actual_hash;
  end if;

  -- 20261107100400 (compute_incentives_bike_allowance)
  v_actual_hash := encode(sha256(convert_to(replace(v_m5_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '1fc60b3e25429d63d252f71d2d4a536cd352264ce1c87060d30cbd53c9732b45' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100400 (compute_incentives_bike_allowance) text does not match its pinned sha256 (expected 1fc60b3e25429d63d252f71d2d4a536cd352264ce1c87060d30cbd53c9732b45, got %)', v_actual_hash;
  end if;

  -- 20261107100500 (compute_salary_itemised_expenses)
  v_actual_hash := encode(sha256(convert_to(replace(v_m6_mig, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from 'bcaeedaad27c6d99217b9300a53619ad41beba9a218aac694b40184b1de7acf8' then
    raise exception 'APPLY_REFUSED: embedded migration 20261107100500 (compute_salary_itemised_expenses) text does not match its pinned sha256 (expected bcaeedaad27c6d99217b9300a53619ad41beba9a218aac694b40184b1de7acf8, got %)', v_actual_hash;
  end if;

  -- 8. RUN -- all 6, in order.
  execute replace(v_m1_mig, E'\r', '');
  execute replace(v_m2_mig, E'\r', '');
  execute replace(v_m3_mig, E'\r', '');
  execute replace(v_m4_mig, E'\r', '');
  execute replace(v_m5_mig, E'\r', '');
  execute replace(v_m6_mig, E'\r', '');

  -- 9. REGISTER -- all 6 versions, same transaction as the migrations themselves.
  insert into supabase_migrations.schema_migrations (version, name, statements) values
    ('20261107100000', 'technician_vehicles', array[replace(v_m1_mig, E'\r', '')]),
    ('20261107100100', 'technician_km_log', array[replace(v_m2_mig, E'\r', '')]),
    ('20261107100200', 'expense_claims', array[replace(v_m3_mig, E'\r', '')]),
    ('20261107100300', 'person_allowances_and_adjustments', array[replace(v_m4_mig, E'\r', '')]),
    ('20261107100400', 'compute_incentives_bike_allowance', array[replace(v_m5_mig, E'\r', '')]),
    ('20261107100500', 'compute_salary_itemised_expenses', array[replace(v_m6_mig, E'\r', '')]);

  -- 10a. compute_incentives / compute_salary still exist and are not anon/PUBLIC-executable.
  if to_regprocedure('public.compute_incentives(uuid,date)') is null
     or to_regprocedure('public.compute_salary(uuid,uuid,date)') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- compute_incentives or compute_salary missing after the migrations ran';
  end if;
  if has_function_privilege('anon', 'public.compute_incentives(uuid,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.compute_salary(uuid,uuid,date)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- compute_incentives or compute_salary is executable by anon/PUBLIC';
  end if;

  -- 10b. the strictly-internal functions must not be anon/PUBLIC-executable either (matches
  -- the rehearsal's own ACL-guard test, which passed 13/13 live).
  if has_function_privilege('anon', 'public.technician_vehicle_on(uuid,uuid,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_own_bike_days(uuid,uuid,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_expense_claims_total(uuid,uuid,date,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.person_allowance_on(uuid,uuid,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.monthly_adjustment_top_up(uuid,uuid,date,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.monthly_adjustment_excluded(uuid,uuid,date,text)', 'EXECUTE') then
    v_internal_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the strictly-internal expense functions is executable by anon/PUBLIC';
  end if;

  -- 10c. DIFF-BASED leak check.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (
    select unnest(v_leaked_after) as x
    except
    select unnest(v_leaked_before)
  ) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- these migrations newly exposed % function(s) to PUBLIC/anon: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 10d. real-org fingerprint unchanged.
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_real_fp_after;

  if v_real_fp_after is distinct from v_real_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real organisation fingerprint changed (before %, after %)',
      v_real_fp_before, v_real_fp_after;
  end if;

  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 11. Every step above passed -- record the one status row.
  insert into pg_temp.monthly_expenses_apply_status (
    versions_registered, functions_exist, functions_not_anon_executable,
    internal_functions_not_anon_executable, newly_leaked_functions,
    org_fingerprint_before, org_fingerprint_after, real_org_fp_before, real_org_fp_after,
    applied_at
  )
  values (
    array['20261107100000','20261107100100','20261107100200','20261107100300','20261107100400','20261107100500'],
    true, not v_anon_exec, not v_internal_anon_exec, v_newly_leaked,
    v_org_fingerprint_before, v_org_fingerprint_after, v_real_fp_before, v_real_fp_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.monthly_expenses_apply_status;
