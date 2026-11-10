-- GO APPLY script for migration 20261108100000_customer_water_profile.sql (customer water/household
-- profile: 4 water columns on customers, a master/operation_admin/sales_admin edit guard, a separate
-- customer_health_profile table with a technician-gated read), commit on feat/customer-water-profile.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 2bbcaeb398118e308def19ffec662c793f011ea48fe823314ed7aaefaef2ba0c), and that the live rehearsal of this
-- exact migration (20261108100000_customer_water_profile.rehearsal.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only adds columns and brand-new objects: 4 nullable columns on
-- customers (water_source, water_source_other, water_tds_ppm, water_ph) plus a check constraint, 1
-- defaulted column on settings (show_health_condition_to_technicians, default false), a brand-new enum
-- type (household_health_level), a brand-new table (customer_health_profile, empty at creation), 3
-- brand-new functions (guard_water_profile_edit_roles, stamp_customer_health_profile,
-- get_customer_health_condition), and 1 brand-new RLS policy on customers
-- (customers_write_operation_admin). It redefines NOTHING that already exists -- confirmed by the
-- rehearsal's own header note and independently re-confirmed here via the new-object prechecks below --
-- so there is no GV_PRECHECK_PROBE section in this script. customers' own pre-existing grants/column
-- privileges are completely untouched, per the migration's own design note.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261108100000, refuse immediately.
--   4. NEW-OBJECT PRE-CHECK -- none of the 3 brand-new functions (via to_regprocedure), the brand-new
--      table customer_health_profile (via to_regclass), or the brand-new enum type
--      household_health_level (via to_regtype) may already exist.
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers, over REAL
--      (non __TEST_) organisations only -- the exact formula the rehearsal used.
--   6. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   7. PIN          -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   8. RUN          -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   9. REGISTER     -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. all 3 new functions, the new table and the new enum type now exist, and
--          customer_health_profile has row level security enabled with its 4 expected policies;
--      10b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      10c. ABSOLUTE check -- anon/PUBLIC cannot execute get_customer_health_condition(uuid),
--          guard_water_profile_edit_roles(), or stamp_customer_health_profile(), independent of 10b;
--          anon has no table privilege at all on customer_health_profile (checked directly, matching the
--          migration's own unconditional `revoke all ... from public, anon, authenticated` followed by a
--          narrow re-grant to authenticated only);
--      10d. the real customers fingerprint is unchanged from step 5 -- this migration touches no
--          existing row.
--   11. On success, INSERT the one status row into pg_temp.customer_water_profile_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.customer_water_profile_apply_status;
create temp table customer_water_profile_apply_status (
  migration_version               text,
  version_registered              boolean,
  new_objects_exist               boolean,
  rls_enabled_and_policies_exist  boolean,
  functions_executable_by_anon    boolean,
  anon_has_no_table_privilege     boolean,
  newly_leaked_functions          text[],
  table_fingerprint_before        text,
  table_fingerprint_after         text,
  table_fingerprint_unchanged     boolean,
  applied_at                      timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := '2bbcaeb398118e308def19ffec662c793f011ea48fe823314ed7aaefaef2ba0c';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261108100000';
  v_already_registered       boolean;
  v_new_objects_exist        boolean := true;
  v_rls_ok                   boolean;
  v_anon_exec                boolean := false;
  v_anon_table_priv          boolean := false;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_count_before          bigint;
  v_fp_count_after           bigint;
  v_fp_md5_before            text;
  v_fp_md5_after             text;
  v_embedded_migration       text := $watermig$-- Customer water and household profile. Spec: FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md.
--
-- Revised per reviewer feedback (2026-10-26, two rounds): health_condition lives in its own
-- table, customer_health_profile, not a customers column. customers' own grants and column
-- privileges are completely untouched by this migration — no revoke/regrant of any kind on
-- public.customers. Water fields (source/TDS/pH) stay on customers as before.
--
-- DESIGN NOTE — who may edit the water fields: master, operation_admin AND sales_admin, per
-- the spec's "same roles that can edit customers today". master and sales_admin already have
-- full customers write access via the pre-existing customers_write_sales policy, so nothing
-- new is needed for them. operation_admin has NO customers write access at all today, so it
-- gets a brand-new policy below — but deliberately only an UPDATE policy, and the trigger
-- further confines it to ONLY the water columns (it may not touch name/mobile/org_id/etc via
-- that path). In short: "operation_admin has trigger-restricted UPDATE on customers" — master
-- and sales_admin are not restricted by the trigger at all (they already have broader access
-- through other means, and the spec doesn't ask for them to be scoped down).

-- ── water profile columns on customers (unchanged shape; reuses the existing
--    water_source_type enum — 20260915180000_ro_water_quality_readings.sql) ───────────────
alter table public.customers
  add column water_source water_source_type,
  add column water_source_other text check (water_source_other is null or char_length(water_source_other) <= 100),
  add column water_tds_ppm numeric(6, 2) check (water_tds_ppm is null or water_tds_ppm >= 0),
  add column water_ph numeric(4, 2) check (water_ph is null or water_ph between 0 and 14);

alter table public.customers
  add constraint customers_water_source_other_only_with_other
  check (water_source_other is null or water_source = 'other');

-- ── role guard for the 4 water columns: master, operation_admin, sales_admin may change
--    them. operation_admin may change ONLY them (it has no other customers write access at
--    all — see the design note above); master/sales_admin are not scoped down, since they
--    already have full customers write access through the pre-existing customers_write_sales
--    policy regardless of this trigger. This governs who may UPDATE these values — it does
--    not touch customers' SELECT grants or any other column's privileges. SECURITY INVOKER:
--    a client-detecting trigger, so no current_user/session_user test is used (that's only
--    disallowed inside SECURITY DEFINER, and isn't needed here either way — it calls the
--    existing current_role() stable helper, same pattern as the pre-existing
--    guard_customer_self_update trigger on this table). auth.uid() is null (a service-role/
--    system connection, not an end-user session) bypasses this trigger entirely, so
--    system/owner/migration-style writes are never blocked by it. ─────────────────────────
create or replace function public.guard_water_profile_edit_roles()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_role public.user_role;
  v_water_changed boolean;
  v_other_changed boolean;
begin
  if auth.uid() is null then
    return new;
  end if;

  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
  );

  v_other_changed := (
    (to_jsonb(new) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
    is distinct from
    (to_jsonb(old) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_role is distinct from 'sales_admin' and v_water_changed then
    raise exception 'customers: only master, operation_admin or sales_admin may edit the water profile fields';
  end if;

  return new;
end;
$$;

create trigger guard_water_profile_edit_roles
  before update on public.customers
  for each row execute function public.guard_water_profile_edit_roles();

-- operation_admin currently has NO write policy on customers at all — this grants it UPDATE
-- only (never insert/delete), org-scoped; the trigger above is what actually confines it to
-- the water columns, since RLS itself is row-level, not column-level.
create policy customers_write_operation_admin on public.customers
  for update
  using (org_id = public.current_org_id() and public.current_role() = 'operation_admin')
  with check (org_id = public.current_org_id() and public.current_role() = 'operation_admin');

-- ── technician visibility switch for health_condition (default off) ────────────────────────
alter table public.settings
  add column show_health_condition_to_technicians boolean not null default false;

-- ── health_condition: its own table. customers is not touched by any of this. ──────────────
create type household_health_level as enum ('none', 'normal', 'medium', 'high');

create table public.customer_health_profile (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  org_id uuid not null references public.organizations (id) on delete cascade,
  health_condition household_health_level not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

create index customer_health_profile_org_id_idx on public.customer_health_profile (org_id);

-- Stamps updated_at/updated_by from the real caller — not an audit trigger (nothing is copied
-- to audit_log or anywhere else), just this row's own metadata. SECURITY INVOKER, no
-- current_user/session_user test.
create or replace function public.stamp_customer_health_profile()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger stamp_customer_health_profile
  before insert or update on public.customer_health_profile
  for each row execute function public.stamp_customer_health_profile();

alter table public.customer_health_profile enable row level security;

-- This project auto-grants default privileges to anon/authenticated on new public-schema
-- objects (see 20260827-era "default_privileges anon EXECUTE leak" fix) — revoke everything
-- first, unconditionally, then grant back only the narrow authenticated access this table
-- actually needs. anon gets nothing at all.
revoke all on public.customer_health_profile from public, anon, authenticated;

-- master, operation_admin, sales_admin of the same org — reusing the existing is_staff()
-- helper (current_role() in ('master','operation_admin','sales_admin')), which is exactly
-- that role set. Read and write; no delete policy (not asked for). WITH CHECK also requires
-- the referenced customer to actually belong to the same org as the row being written —
-- without this, staff of one org could plant (or move) a health_condition row for a
-- customer_id that actually belongs to a different org, by simply quoting their own org_id
-- in the insert/update. The subquery's columns are explicitly table-qualified on BOTH sides
-- (customer_health_profile.customer_id / customer_health_profile.org_id vs c.id / c.org_id) —
-- leaving org_id unqualified here would resolve to c.org_id inside the subquery's own scope
-- (closest enclosing alias wins), making "c.org_id = org_id" a tautology that never actually
-- compares against the row being written.
create policy customer_health_profile_staff_select on public.customer_health_profile
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_health_profile_staff_insert on public.customer_health_profile
  for insert
  with check (
    org_id = public.current_org_id()
    and public.is_staff()
    and exists (
      select 1 from public.customers c
      where c.id = customer_health_profile.customer_id and c.org_id = customer_health_profile.org_id
    )
  );
create policy customer_health_profile_staff_update on public.customer_health_profile
  for update
  using (org_id = public.current_org_id() and public.is_staff())
  with check (
    org_id = public.current_org_id()
    and public.is_staff()
    and exists (
      select 1 from public.customers c
      where c.id = customer_health_profile.customer_id and c.org_id = customer_health_profile.org_id
    )
  );

-- the customer — their own row, read-only (no insert/update policy for the customer role).
create policy customer_health_profile_select_own on public.customer_health_profile
  for select using (customer_id = public.current_customer_id());

-- Technicians get no policy at all here — zero table access, by omission.
grant select, insert, update on public.customer_health_profile to authenticated;

-- ── gated read, a technician's ONLY path to this value (SECURITY DEFINER, bypasses RLS/
--    grants entirely — not affected by anything above). Staff always; the customer, their
--    own row; a technician, only when the org setting is on AND they have (or had) an
--    appointment with that customer — same exists() shape as the pre-existing
--    customers_select_own_technician RLS policy. The customer_health_profile lookup is
--    scoped by both customer_id AND org_id (belt-and-suspenders — customer_id is already
--    unique and already org-checked via v_org_id above, but this costs nothing and rules out
--    any possible cross-org row entirely at the SQL level, not just by construction). ───────
create or replace function public.get_customer_health_condition(p_customer_id uuid)
returns household_health_level
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_level household_health_level;
  v_technician_id uuid := public.current_technician_id();
begin
  select org_id into v_org_id from public.customers where id = p_customer_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    return null;
  end if;

  select health_condition into v_level
  from public.customer_health_profile
  where customer_id = p_customer_id and org_id = v_org_id;

  if public.is_staff() then
    return v_level;
  end if;

  if p_customer_id = public.current_customer_id() then
    return v_level;
  end if;

  if v_technician_id is not null
     and exists (select 1 from public.settings s where s.org_id = v_org_id and s.show_health_condition_to_technicians)
     and exists (
       select 1
       from public.service_tickets t
       join public.appointments a on a.ticket_id = t.id
       where t.customer_id = p_customer_id and a.technician_id = v_technician_id
     )
  then
    return v_level;
  end if;

  return null;
end;
$$;

revoke all on function public.get_customer_health_condition(uuid) from public, anon;
grant execute on function public.get_customer_health_condition(uuid) to authenticated;
$watermig$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
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
  if to_regprocedure('public.guard_water_profile_edit_roles()') is not null then
    raise exception 'APPLY_REFUSED: public.guard_water_profile_edit_roles() already exists live before this migration ran';
  end if;
  if to_regprocedure('public.stamp_customer_health_profile()') is not null then
    raise exception 'APPLY_REFUSED: public.stamp_customer_health_profile() already exists live before this migration ran';
  end if;
  if to_regprocedure('public.get_customer_health_condition(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.get_customer_health_condition(uuid) already exists live before this migration ran';
  end if;
  if to_regclass('public.customer_health_profile') is not null then
    raise exception 'APPLY_REFUSED: public.customer_health_profile already exists live before this migration ran';
  end if;
  if to_regtype('public.household_health_level') is not null then
    raise exception 'APPLY_REFUSED: public.household_health_level already exists live before this migration ran';
  end if;

  -- 5. REAL-TABLE FINGERPRINT (BEFORE) -- customers, REAL organisations only (same formula the
  -- rehearsal used: count + md5 of every id||updated_at pair).
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_fp_count_before, v_fp_md5_before
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

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
  values (v_migration_version, 'customer_water_profile', array[replace(v_embedded_migration, E'\r', '')]);

  -- 10a. all 3 new functions, the new table and the new enum type exist; RLS enabled with its
  -- 4 expected policies.
  v_new_objects_exist :=
    (to_regprocedure('public.guard_water_profile_edit_roles()') is not null)
    and (to_regprocedure('public.stamp_customer_health_profile()') is not null)
    and (to_regprocedure('public.get_customer_health_condition(uuid)') is not null)
    and (to_regclass('public.customer_health_profile') is not null)
    and (to_regtype('public.household_health_level') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or more new functions/table/type are missing after the migration ran';
  end if;

  select c.relrowsecurity
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.customer_health_profile'::regclass and pol.polname = 'customer_health_profile_staff_select')
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.customer_health_profile'::regclass and pol.polname = 'customer_health_profile_staff_insert')
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.customer_health_profile'::regclass and pol.polname = 'customer_health_profile_staff_update')
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.customer_health_profile'::regclass and pol.polname = 'customer_health_profile_select_own')
    into v_rls_ok
    from pg_class c
    where c.oid = 'public.customer_health_profile'::regclass;

  if not coalesce(v_rls_ok, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_health_profile is missing row level security or one of its 4 expected policies';
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

  -- 10c. ABSOLUTE checks -- anon/PUBLIC cannot execute any of the 3 new functions, and has no
  -- table privilege at all on customer_health_profile.
  if has_function_privilege('anon', 'public.guard_water_profile_edit_roles()', 'EXECUTE')
     or has_function_privilege('anon', 'public.stamp_customer_health_profile()', 'EXECUTE')
     or has_function_privilege('anon', 'public.get_customer_health_condition(uuid)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one new function is executable by anon/PUBLIC';
  end if;
  if has_table_privilege('anon', 'public.customer_health_profile', 'SELECT')
     or has_table_privilege('anon', 'public.customer_health_profile', 'INSERT')
     or has_table_privilege('anon', 'public.customer_health_profile', 'UPDATE') then
    v_anon_table_priv := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon has a table privilege on public.customer_health_profile';
  end if;

  -- 10d. the real customers fingerprint is unchanged.
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_fp_count_after, v_fp_md5_after
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  if v_fp_count_after is distinct from v_fp_count_before or v_fp_md5_after is distinct from v_fp_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real customers fingerprint changed (count before % after %, md5 before % after %)',
      v_fp_count_before, v_fp_count_after, v_fp_md5_before, v_fp_md5_after;
  end if;

  -- 11. Every step above passed -- record the one status row.
  insert into pg_temp.customer_water_profile_apply_status (
    migration_version, version_registered, new_objects_exist, rls_enabled_and_policies_exist,
    functions_executable_by_anon, anon_has_no_table_privilege, newly_leaked_functions,
    table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_rls_ok,
    v_anon_exec, not v_anon_table_priv, v_newly_leaked,
    v_fp_count_before::text || '|' || v_fp_md5_before, v_fp_count_after::text || '|' || v_fp_md5_after,
    (v_fp_count_after = v_fp_count_before and v_fp_md5_after = v_fp_md5_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_water_profile_apply_status;
