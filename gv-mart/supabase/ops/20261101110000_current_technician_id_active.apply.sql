-- GO APPLY script for migration 20261101110000_current_technician_id_active.sql (P1b: a deactivated
-- technician is not a technician for RLS), commit ec89c6d on integration/p-series.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- a64bf7ad63d9ab2501a5da7147f95a9986945e73231c8b612f49769105523a40), and that the live rehearsal of this
-- exact migration (rehearsal_20261101110000_current_technician_id_active.sql, wrapper sha256
-- 9de3413abcc31211e6f973ac56e05a55fb2dbcea124232ad50c51c31accc3b0b) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total, run in order in the same session: (1) CREATE TEMP TABLE for the status
-- row, autocommitted on its own; (2) the DO block itself; (3) a read-only SELECT from that temp table.
-- Unlike the rehearsal wrapper, THIS SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only redefines one existing function
-- (public.current_technician_id()) via CREATE OR REPLACE, adding an `and t.is_active` clause to its body.
-- It issues no INSERT/UPDATE/DELETE against any table's rows. The pre/post fingerprint below (technicians
-- row-level fingerprint, same formula as the rehearsal) exists purely to prove that holds live.
--
-- PREREQUISITE (not checked by this script, carried over unchanged from the rehearsal's own header note):
-- migration 20261024100000_close_public_and_anon_function_execute must already be applied on the target
-- database for current_technician_id() to have no PUBLIC grant after this migration's CREATE OR REPLACE
-- (CREATE OR REPLACE preserves the existing ACL). It is applied live; this script does not re-verify it.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261101110000, refuse immediately.
--   4. LIVE-DEFINITION PRE-CHECK -- public.current_technician_id() redefines an EXISTING function (created
--      by 20260701091200_functions_triggers.sql). GV_PRECHECK_PROBE pattern: hash the live definition, then
--      inside a sub-block that is always rolled back, apply the pinned pre-P1b text and hash it again --
--      if the two differ, something else already changed this function live since the rehearsal was
--      approved, and the apply refuses rather than silently building on top of an unreviewed change.
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- the same technicians row-level fingerprint (id + is_active) the
--      rehearsal used, over REAL (non __TEST_) organisations only.
--   6. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon, before touching anything.
--   7. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   8. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   9. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. the live definition of current_technician_id() now matches the NEW (post-P1b) text exactly
--          (md5 of pg_get_functiondef, compared against a pinned expected md5 computed the same way);
--      10b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot. CREATE OR REPLACE never changes grants, so this is expected to
--          come back empty regardless, but it is still checked, not assumed;
--      10c. current_technician_id() is still not executable by anon/PUBLIC (absolute, independent of 10b --
--          this function was already locked down before P1b and must stay that way);
--      10d. the real technicians fingerprint is unchanged from step 5 -- this migration touches no table
--          rows at all, only a function definition.
--   11. On success, INSERT the one status row into pg_temp.current_technician_id_active_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at
-- supabase/rollbacks/20261101110000_current_technician_id_active.rollback.sql and is run by hand, outside
-- this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.current_technician_id_active_apply_status;
create temp table current_technician_id_active_apply_status (
  migration_version              text,
  version_registered             boolean,
  definition_updated              boolean,
  function_executable_by_anon     boolean,
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
  v_expected_migration_hash  text := 'a64bf7ad63d9ab2501a5da7147f95a9986945e73231c8b612f49769105523a40';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261101110000';
  v_already_registered       boolean;
  v_text                     text;
  v_hash                     text;
  v_live                     text;
  v_orig                     text;
  v_post_md5                 text;
  v_anon_exec                boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p1bmig$-- P1b (security audit): a deactivated technician is not a technician for RLS.
-- Design: gv-mart/docs/design-p1-task-security.md
--
-- current_technician_id() now also requires technicians.is_active. Every policy and function that keys on it (tasks, jobs, customer
-- history, ...) stops matching a deactivated technician immediately. create or replace keeps the existing ACL (one of the helper
-- functions that must stay executable by the roles RLS runs as).
--
-- Rollback: supabase/rollbacks/20261101110000_current_technician_id_active.rollback.sql

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select t.id from public.technicians t where t.profile_id = auth.uid() and t.is_active $$;
$p1bmig$;
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

  -- 4. LIVE-DEFINITION PRE-CHECK -- public.current_technician_id() must still be its pre-P1b definition
  -- (20260701091200). Probe: hash the live definition, apply the pinned pre-P1b text inside a sub-block
  -- that always rolls back, hash again, compare.
  v_text := $ctichk$create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;$ctichk$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '8d4acb9ff750cbca42a26fc312c37f69a9c7bec8d5800f30efb9b22229b73aa1' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (current_technician_id): %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public.current_technician_id()'::regprocedure));
  begin
    execute replace(v_text, E'\r', '');
    v_orig := md5(pg_get_functiondef('public.current_technician_id()'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live public.current_technician_id() (md5 %) differs from its pre-P1b definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 5. REAL-TABLE FINGERPRINT (BEFORE) -- technicians (id + is_active), REAL organisations only.
  select md5(coalesce((select string_agg(t.id::text || ':' || t.is_active::text, ',' order by t.id)
                     from public.technicians t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.technicians t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
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
  values (v_migration_version, 'current_technician_id_active', array[replace(v_embedded_migration, E'\r', '')]);

  -- 10a. the live definition now differs from its pre-P1b md5 (v_live, captured in step 4) -- i.e. RUN
  -- actually changed it. pg_get_functiondef() re-renders Postgres's own canonical form rather than the
  -- literal source text, so a direct string compare against the embedded CREATE text would be unreliable;
  -- "it changed at all from the known pre-P1b body" is the reliable signal, with 10b/10c below separately
  -- confirming the new body is still correctly locked down.
  v_post_md5 := md5(pg_get_functiondef('public.current_technician_id()'::regprocedure));
  if v_post_md5 is distinct from v_live then
    null; -- expected: it changed
  else
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.current_technician_id() definition did not change after the migration ran (still matches its pre-P1b md5 %)',
      v_live;
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

  -- 10c. current_technician_id() is still not executable by anon/PUBLIC -- absolute, independent of 10b.
  select has_function_privilege('anon', 'public.current_technician_id()', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.current_technician_id() is executable by anon/PUBLIC';
  end if;

  -- 10d. the real technicians fingerprint is unchanged -- this migration touches no table rows.
  select md5(coalesce((select string_agg(t.id::text || ':' || t.is_active::text, ',' order by t.id)
                     from public.technicians t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.technicians t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real technicians fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 11. Every step above passed -- record the one status row.
  insert into pg_temp.current_technician_id_active_apply_status (
    migration_version, version_registered, definition_updated, function_executable_by_anon,
    newly_leaked_functions, table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, (v_post_md5 is distinct from v_live), v_anon_exec,
    v_newly_leaked, v_fp_before, v_fp_after,
    (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.current_technician_id_active_apply_status;
