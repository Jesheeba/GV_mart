-- GO APPLY script for migration 20261107100000_technician_vehicles.sql (Monthly Expenses Unit 1: bike
-- ownership/petrol-rate per technician, effective-dated), commit on feat/monthly-expenses-v2.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 13586709047ccc74cc36b63337b4178e6bd98637378a38105722d30383d4d32a), and that the live rehearsal of this
-- migration (part of rehearse_combined_all_units.sql, run first in that combined wrapper) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration enables the btree_gist extension (idempotent, IF NOT EXISTS) and
-- creates one brand-new table (technician_vehicles, empty at creation) with its RLS/policies/grants/audit
-- trigger, plus 2 brand-new functions (technician_vehicle_on, technician_own_bike_days). It writes no
-- existing row.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261107100000, refuse immediately.
--   4. NEW-OBJECT PRE-CHECK -- neither technician_vehicle_on(uuid,uuid,date) nor
--      technician_own_bike_days(uuid,uuid,date) may already exist; nor may public.technician_vehicles.
--   5. REAL-DATA FINGERPRINT (BEFORE) -- the salaries/incentives_earned/settings fingerprint used
--      throughout this release's expenses package (same formula the combined rehearsal used, with the
--      not-yet-existing own_bike_allowance_base settings key removed from the comparison via jsonb `-`,
--      a no-op until migration 4 adds it, so the same expression is valid at every checkpoint).
--   6. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   7. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   8. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   9. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. the table and both new functions now exist;
--      10b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      10c. ABSOLUTE check -- anon/PUBLIC cannot execute either new function, independent of 10b (the
--          migration's own text already revokes this explicitly; checked independently here);
--      10d. the real fingerprint (same formula as step 5) is unchanged.
--   11. On success, INSERT the one status row into pg_temp.technician_vehicles_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.technician_vehicles_apply_status;
create temp table technician_vehicles_apply_status (
  migration_version              text,
  version_registered             boolean,
  new_objects_exist              boolean,
  functions_executable_by_anon   boolean,
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
  v_expected_migration_hash  text := '13586709047ccc74cc36b63337b4178e6bd98637378a38105722d30383d4d32a';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261107100000';
  v_already_registered       boolean;
  v_new_objects_exist        boolean := true;
  v_anon_exec                boolean := false;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $em1$-- Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md), Unit 1 — bike
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
$em1$;
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

  -- 4. NEW-OBJECT PRE-CHECK.
  if to_regprocedure('public.technician_vehicle_on(uuid,uuid,date)') is not null then
    raise exception 'APPLY_REFUSED: public.technician_vehicle_on(uuid,uuid,date) already exists live before this migration ran';
  end if;
  if to_regprocedure('public.technician_own_bike_days(uuid,uuid,date)') is not null then
    raise exception 'APPLY_REFUSED: public.technician_own_bike_days(uuid,uuid,date) already exists live before this migration ran';
  end if;
  if to_regclass('public.technician_vehicles') is not null then
    raise exception 'APPLY_REFUSED: public.technician_vehicles already exists live before this migration ran';
  end if;

  -- 5. REAL-DATA FINGERPRINT (BEFORE) -- salaries + incentives_earned + settings, same formula used
  -- throughout this expenses package (own_bike_allowance_base removed from the settings comparison,
  -- a no-op until migration 4 adds it).
  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org),
      (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s where org_id = v_org))
    into v_fp_before;

  -- 6. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
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

  -- 7. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 8. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 9. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'technician_vehicles', array[replace(v_embedded_migration, E'\r', '')]);

  -- 10a. the table and both new functions exist.
  v_new_objects_exist :=
    (to_regclass('public.technician_vehicles') is not null)
    and (to_regprocedure('public.technician_vehicle_on(uuid,uuid,date)') is not null)
    and (to_regprocedure('public.technician_own_bike_days(uuid,uuid,date)') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the new table and/or functions are missing after the migration ran';
  end if;

  -- 10b. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
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

  -- 10c. ABSOLUTE check -- anon/PUBLIC cannot execute either new function, independent of 10b.
  if has_function_privilege('anon', 'public.technician_vehicle_on(uuid, uuid, date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_own_bike_days(uuid, uuid, date)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one new function is executable by anon/PUBLIC';
  end if;

  -- 10d. the real fingerprint (same formula as step 5) is unchanged.
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

  -- 11. Every step above passed -- record the one status row.
  insert into pg_temp.technician_vehicles_apply_status (
    migration_version, version_registered, new_objects_exist, functions_executable_by_anon,
    newly_leaked_functions, data_fingerprint_before, data_fingerprint_after, data_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_anon_exec,
    v_newly_leaked, v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.technician_vehicles_apply_status;
