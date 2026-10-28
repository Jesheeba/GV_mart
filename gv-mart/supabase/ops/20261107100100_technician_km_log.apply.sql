-- GO APPLY script for migration 20261107100100_technician_km_log.sql (Monthly Expenses Unit 2:
-- append-only kilometre log + 3 read RPCs), commit on feat/monthly-expenses-v2.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 4b2c5f0a450d770b609f74d78ac9ad6d18392727ee2f4b11e3f5180e481d3ca8), that 20261107100000 has ALREADY
-- been applied for real (this script checks, see step 4), and that the live rehearsal of this migration
-- (part of rehearse_combined_all_units.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration creates one brand-new table (technician_km_log, empty at
-- creation, append-only: no update/delete policy for any role) with its RLS/policies/grants, plus 3
-- brand-new functions (technician_km_log_sum, technician_petrol_reference_amount --
-- technician_petrol_reference_amount reads technician_vehicles, created by 20261107100000 --
-- technician_approx_distance_km). It writes no existing row.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261107100100, refuse immediately.
--   4. PREREQUISITE CHECK -- 20261107100000 must already be registered (technician_petrol_reference_amount
--      reads public.technician_vehicles, created by that migration).
--   5. NEW-OBJECT PRE-CHECK -- neither the table nor any of the 3 new functions may already exist.
--   6. REAL-DATA FINGERPRINT (BEFORE) -- the same salaries/incentives_earned/settings fingerprint used
--      throughout this package.
--   7. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   8. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   9. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   10. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   11. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      11a. the table and all 3 new functions now exist;
--      11b. DIFF-BASED leak check;
--      11c. ABSOLUTE check -- anon/PUBLIC cannot execute any of the 3 new functions, independent of 11b
--          (the migration's own text already revokes this explicitly for anon; checked independently
--          here); `authenticated` CAN execute all 3 (checked informationally, not enforced);
--      11d. the real fingerprint (same formula as step 6) is unchanged.
--   12. On success, INSERT the one status row into pg_temp.technician_km_log_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.technician_km_log_apply_status;
create temp table technician_km_log_apply_status (
  migration_version              text,
  version_registered             boolean,
  new_objects_exist              boolean,
  functions_executable_by_anon   boolean,
  authenticated_can_execute_all  boolean,
  newly_leaked_functions         text[],
  data_fingerprint_before        text,
  data_fingerprint_after         text,
  data_fingerprint_unchanged     boolean,
  applied_at                     timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_org                      uuid;
  v_expected_migration_hash  text := '4b2c5f0a450d770b609f74d78ac9ad6d18392727ee2f4b11e3f5180e481d3ca8';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261107100100';
  v_already_registered       boolean;
  v_prereq_registered        boolean;
  v_new_objects_exist        boolean := true;
  v_anon_exec                boolean := false;
  v_auth_exec                boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $em2$-- Monthly Expenses spec, Unit 2 — kilometre log (§1.5/§3.2). Append-only: no
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
$em2$;
begin
  -- 0. ORG CHECK
  select o.id, md5(o.id::text || '|' || o.name) into v_org, v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST (owner decision, 2026-10-28).
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied',
      v_migration_version;
  end if;

  -- 4. PREREQUISITE CHECK -- 20261107100000 must already be applied.
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261107100000') into v_prereq_registered;
  if not v_prereq_registered then
    raise exception 'APPLY_REFUSED: prerequisite 20261107100000 is not yet registered in supabase_migrations.schema_migrations -- apply it first';
  end if;
  if to_regclass('public.technician_vehicles') is null then
    raise exception 'APPLY_REFUSED: prerequisite check failed -- public.technician_vehicles does not exist; 20261107100000 does not appear to be live despite its version row';
  end if;

  -- 5. NEW-OBJECT PRE-CHECK.
  if to_regclass('public.technician_km_log') is not null then
    raise exception 'APPLY_REFUSED: public.technician_km_log already exists live before this migration ran';
  end if;
  if to_regprocedure('public.technician_km_log_sum(uuid,uuid,date)') is not null then
    raise exception 'APPLY_REFUSED: public.technician_km_log_sum(uuid,uuid,date) already exists live before this migration ran';
  end if;
  if to_regprocedure('public.technician_petrol_reference_amount(uuid,uuid,date)') is not null then
    raise exception 'APPLY_REFUSED: public.technician_petrol_reference_amount(uuid,uuid,date) already exists live before this migration ran';
  end if;
  if to_regprocedure('public.technician_approx_distance_km(uuid,uuid,date)') is not null then
    raise exception 'APPLY_REFUSED: public.technician_approx_distance_km(uuid,uuid,date) already exists live before this migration ran';
  end if;

  -- 6. REAL-DATA FINGERPRINT (BEFORE).
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_before;

  -- 7. LEAK SNAPSHOT (BEFORE).
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

  -- 8. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 9. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 10. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'technician_km_log', array[replace(v_embedded_migration, E'\r', '')]);

  -- 11a. the table and all 3 new functions exist.
  v_new_objects_exist :=
    (to_regclass('public.technician_km_log') is not null)
    and (to_regprocedure('public.technician_km_log_sum(uuid,uuid,date)') is not null)
    and (to_regprocedure('public.technician_petrol_reference_amount(uuid,uuid,date)') is not null)
    and (to_regprocedure('public.technician_approx_distance_km(uuid,uuid,date)') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the new table and/or functions are missing after the migration ran';
  end if;

  -- 11b. DIFF-BASED leak check.
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 11c. ABSOLUTE check -- anon/PUBLIC cannot execute any of the 3 new functions, independent of 11b.
  if has_function_privilege('anon', 'public.technician_km_log_sum(uuid, uuid, date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_petrol_reference_amount(uuid, uuid, date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_approx_distance_km(uuid, uuid, date)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one new function is executable by anon/PUBLIC';
  end if;
  select has_function_privilege('authenticated', 'public.technician_km_log_sum(uuid, uuid, date)', 'EXECUTE')
         and has_function_privilege('authenticated', 'public.technician_petrol_reference_amount(uuid, uuid, date)', 'EXECUTE')
         and has_function_privilege('authenticated', 'public.technician_approx_distance_km(uuid, uuid, date)', 'EXECUTE')
    into v_auth_exec;

  -- 11d. the real fingerprint is unchanged.
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 12. Every step above passed -- record the one status row.
  insert into pg_temp.technician_km_log_apply_status (
    migration_version, version_registered, new_objects_exist, functions_executable_by_anon,
    authenticated_can_execute_all, newly_leaked_functions,
    data_fingerprint_before, data_fingerprint_after, data_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_anon_exec,
    v_auth_exec, v_newly_leaked, v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.technician_km_log_apply_status;
