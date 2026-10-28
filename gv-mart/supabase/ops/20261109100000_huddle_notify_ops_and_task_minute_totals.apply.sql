-- GO APPLY script for migration 20261109100000_huddle_notify_ops_and_task_minute_totals.sql (Step 3:
-- notify operation_admin too on huddle events, per-task/per-person minute-total views), commit 184717a on
-- integration/p-series.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 37d499edf565f3c140341888956c8341d45e73900b62b0a12a04baa7a9fed678), that P2 and P3 have ALREADY been
-- applied for real (this script checks, see step 4, but does not chain or re-run them -- unlike the
-- rehearsal wrapper this was modeled on, which chains P2 inside the same throwaway transaction because
-- none of P1a/P1b/P2/P3 existed live yet when that rehearsal ran), and that the live rehearsal of this
-- exact migration (rehearsal_20261109100000_huddle_notify_ops_and_task_minute_totals.sql, wrapper sha256
-- bb263320fd1f83b418b0eb36f285588c2748ed54ed3d4907a271cde8a60f2ba4, 11:00 gate used for that rehearsal
-- only) came back clean (17/17 PASS).
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only redefines one existing function
-- (_trg_meeting_issue_notify, created by P2 20261102100000 -- the only change is the role filter, from
-- = 'master' to in ('master', 'operation_admin')) and creates two brand-new, empty-by-construction VIEWS
-- (task_minute_totals, person_minute_totals -- plain aggregates over task_logs/tasks, security_invoker so
-- RLS on those tables runs as the caller, not the view owner). It issues no INSERT/UPDATE/DELETE against
-- any table's rows. The pre/post fingerprint below (notifications/meeting_issues/task_logs, same formula
-- the rehearsal's test used) exists purely to prove that holds live.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window -- this is the production gate, distinct from the one-off 11:00 gate
--      the Step 3 REHEARSAL used for its 2026-10-28 daytime run; here it is the real, standing release gate).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261109100000, refuse immediately.
--   4. PREREQUISITE CHECK -- P2 (20261102100000) and P3 (20261103100000) must ALREADY be registered, AND
--      public.task_logs must already exist (P3's own table -- the two new views select from it and would
--      fail at CREATE VIEW time otherwise, so this is also a technical, not just logical, dependency).
--   5. LIVE-DEFINITION PRE-CHECK -- public._trg_meeting_issue_notify() is the ONE function this migration
--      redefines (created by P2). GV_PRECHECK_PROBE pattern: hash the live definition, apply the pinned
--      pre-Step-3 (i.e. P2's own) text inside a sub-block that always rolls back, hash again, compare --
--      this is the "run against the REAL live function, not a rehearsal stand-in" check: if P2 were
--      somehow not actually live despite its version row existing, or if someone changed this function
--      live since the rehearsal was approved, this refuses.
--   6. NEW-OBJECT PRE-CHECK -- neither task_minute_totals nor person_minute_totals may already exist
--      (`create view` has no OR REPLACE in this migration, so Postgres's own DDL would already refuse and
--      roll the whole block back if either existed -- checked anyway, defensively, with to_regclass).
--   7. REAL-DATA FINGERPRINT (BEFORE) -- the same notifications(huddle_%)/meeting_issues/task_logs
--      fingerprint the rehearsal's test computed (md5 string-agg of each, over REAL organisations only).
--   8. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon (defensive -- this migration creates no new function, only redefines one that was
--      already revoked-all, and two views, which this check does not cover; view-level grants are checked
--      directly in 12c instead).
--   9. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   10. RUN        -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   11. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   12. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      12a. both new views exist and are security_invoker;
--      12b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      12c. ABSOLUTE check -- anon/PUBLIC cannot execute _trg_meeting_issue_notify() and cannot SELECT
--          either new view; `authenticated` CAN SELECT both views (checked informationally, not enforced,
--          since RLS is the real per-row gate, not the table/view grant);
--      12d. the real notifications/meeting_issues/task_logs fingerprint is unchanged from step 7.
--   13. On success, INSERT the one status row into
--      pg_temp.huddle_notify_ops_and_task_minute_totals_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at
-- supabase/rollbacks/20261109100000_huddle_notify_ops_and_task_minute_totals.rollback.sql and is run by
-- hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.huddle_notify_ops_and_task_minute_totals_apply_status;
create temp table huddle_notify_ops_and_task_minute_totals_apply_status (
  migration_version              text,
  version_registered             boolean,
  views_exist_and_security_invoker boolean,
  anon_cannot_access               boolean,
  authenticated_can_select_views   boolean,
  newly_leaked_functions           text[],
  data_fingerprint_before          text,
  data_fingerprint_after           text,
  data_fingerprint_unchanged       boolean,
  applied_at                       timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := '37d499edf565f3c140341888956c8341d45e73900b62b0a12a04baa7a9fed678';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261109100000';
  v_already_registered       boolean;
  v_p2_registered            boolean;
  v_p3_registered            boolean;
  v_text                     text;
  v_hash                     text;
  v_live                     text;
  v_orig                     text;
  v_views_ok                 boolean := true;
  v_anon_blocked             boolean := true;
  v_auth_select              boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $step3mig$-- Window P, Step 3 verification follow-up (client items 3 and 5).
--
--   1. _trg_meeting_issue_notify (20261102100000) notified the master only when a huddle problem was raised,
--      a solution given, or an issue solved. The acceptance criterion is master AND operation_admin. Fixes the
--      role filter from = 'master' to in ('master', 'operation_admin').
--   2. task_minute_totals / person_minute_totals: plain views over task_logs so a screen can show total time
--      logged per task and cumulative per person, without pulling every log row client-side. These are views,
--      not functions, and carry no privilege of their own to leak: WITH (security_invoker = true) makes
--      Postgres evaluate task_logs' and tasks' row security as the CALLING role, not the view owner (the
--      migration runs as postgres, which bypasses RLS — without security_invoker a view created here would
--      silently show every organisation's data to every caller. PG15+, which this project runs on Supabase).
--
-- Rollback: supabase/rollbacks/20261109100000_huddle_notify_ops_and_task_minute_totals.rollback.sql

-- 1. the master AND operation_admin are told --------------------------------------------------------------------------
create or replace function public._trg_meeting_issue_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_title text;
  v_who text;
begin
  if tg_op = 'INSERT' then
    v_type := 'huddle_problem_raised';
    v_title := 'Problem raised in the huddle';
  elsif new.status = 'solved' and old.status is distinct from 'solved' then
    v_type := 'huddle_issue_solved';
    v_title := 'Huddle problem marked solved';
  elsif new.solution is distinct from old.solution and btrim(coalesce(new.solution, '')) <> '' then
    v_type := 'huddle_solution_given';
    v_title := 'Solution given for a huddle problem';
  else
    return new;
  end if;

  select full_name into v_who from public.profiles where id = auth.uid();
  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select new.org_id, p.id, v_type, v_title,
         left(new.description, 140) || case when v_who is not null then ' (' || v_who || ')' else '' end,
         new.id
  from public.profiles p
  where p.org_id = new.org_id and p.role::text in ('master', 'operation_admin') and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;
revoke all on function public._trg_meeting_issue_notify() from public, anon, authenticated;

-- 2. time totals --------------------------------------------------------------------------------------------------------
create view public.task_minute_totals
  with (security_invoker = true)
as
  select task_id, sum(minutes_spent) as total_minutes
  from public.task_logs
  where minutes_spent is not null
  group by task_id;
revoke all on public.task_minute_totals from public, anon, authenticated;
grant select on public.task_minute_totals to authenticated;

create view public.person_minute_totals
  with (security_invoker = true)
as
  select t.assignee_id as profile_id, sum(l.minutes_spent) as total_minutes
  from public.task_logs l
  join public.tasks t on t.id = l.task_id
  where l.minutes_spent is not null and t.assignee_id is not null
  group by t.assignee_id;
revoke all on public.person_minute_totals from public, anon, authenticated;
grant select on public.person_minute_totals to authenticated;

notify pgrst, 'reload schema';
$step3mig$;
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

  -- 2. GATE -- 11:00 IST (owner decision, 2026-10-28; the standing release gate, not the one-off rehearsal
  -- gate from the 2026-10-28 daytime Step 3 rehearsal run).
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

  -- 4. PREREQUISITE CHECK -- P2 and P3 must already be applied. public.task_logs (P3's own table) must
  -- already exist -- the two new views select from it and would fail at CREATE VIEW time otherwise, so
  -- this is a technical dependency, not just a logical one.
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261102100000') into v_p2_registered;
  if not v_p2_registered then
    raise exception 'APPLY_REFUSED: prerequisite P2 (20261102100000) is not yet registered in supabase_migrations.schema_migrations -- apply P2 first';
  end if;
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261103100000') into v_p3_registered;
  if not v_p3_registered then
    raise exception 'APPLY_REFUSED: prerequisite P3 (20261103100000) is not yet registered in supabase_migrations.schema_migrations -- apply P3 first';
  end if;
  if to_regclass('public.task_logs') is null then
    raise exception 'APPLY_REFUSED: prerequisite check failed -- public.task_logs does not exist; P3 does not appear to be live despite its version row';
  end if;

  -- 5. LIVE-DEFINITION PRE-CHECK -- public._trg_meeting_issue_notify() must still be the definition P2
  -- gave it (role filter = 'master' only), run against the REAL live function, not a rehearsal stand-in.
  -- GV_PRECHECK_PROBE: hash the live definition, apply the pinned pre-Step-3 text inside a sub-block that
  -- always rolls back, hash again, compare.
  v_text := $p2orig$create or replace function public._trg_meeting_issue_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_title text;
  v_who text;
begin
  if tg_op = 'INSERT' then
    v_type := 'huddle_problem_raised';
    v_title := 'Problem raised in the huddle';
  elsif new.status = 'solved' and old.status is distinct from 'solved' then
    v_type := 'huddle_issue_solved';
    v_title := 'Huddle problem marked solved';
  elsif new.solution is distinct from old.solution and btrim(coalesce(new.solution, '')) <> '' then
    v_type := 'huddle_solution_given';
    v_title := 'Solution given for a huddle problem';
  else
    return new;
  end if;

  select full_name into v_who from public.profiles where id = auth.uid();
  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select new.org_id, p.id, v_type, v_title,
         left(new.description, 140) || case when v_who is not null then ' (' || v_who || ')' else '' end,
         new.id
  from public.profiles p
  where p.org_id = new.org_id and p.role::text = 'master' and p.is_active and p.id is distinct from auth.uid();
  return new;
end;
$$;$p2orig$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '5c9442573cb641807961c25ab482111cb0858ce1ab19d708d71953402f59e364' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (_trg_meeting_issue_notify, pre-Step-3/P2 body): %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public._trg_meeting_issue_notify()'::regprocedure));
  begin
    execute replace(v_text, E'\r', '');
    v_orig := md5(pg_get_functiondef('public._trg_meeting_issue_notify()'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live public._trg_meeting_issue_notify() (md5 %) differs from its pre-Step-3 (P2) definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 6. NEW-OBJECT PRE-CHECK -- neither new view may already exist.
  if to_regclass('public.task_minute_totals') is not null then
    raise exception 'APPLY_REFUSED: public.task_minute_totals already exists live before this migration ran';
  end if;
  if to_regclass('public.person_minute_totals') is not null then
    raise exception 'APPLY_REFUSED: public.person_minute_totals already exists live before this migration ran';
  end if;

  -- 7. REAL-DATA FINGERPRINT (BEFORE) -- notifications(huddle_%) + meeting_issues + task_logs, REAL
  -- organisations only (same formula the rehearsal's test computed).
  select md5(coalesce((select string_agg(n.id::text || ':' || n.type || ':' || coalesce(n.user_id::text,'-'), ',' order by n.id)
                     from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%'), ''))
         || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || coalesce(i.solution,'-'), ',' order by i.id)
                     from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.task_logs l where l.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_before;

  -- 8. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon
  -- (defensive; this migration creates no new function).
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

  -- 9. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 10. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 11. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'huddle_notify_ops_and_task_minute_totals', array[replace(v_embedded_migration, E'\r', '')]);

  -- 12a. both new views exist and are security_invoker.
  select
    (to_regclass('public.task_minute_totals') is not null)
    and (to_regclass('public.person_minute_totals') is not null)
    and (select coalesce(reloptions, array[]::text[]) @> array['security_invoker=true'] from pg_class where oid = to_regclass('public.task_minute_totals'))
    and (select coalesce(reloptions, array[]::text[]) @> array['security_invoker=true'] from pg_class where oid = to_regclass('public.person_minute_totals'))
    into v_views_ok;

  if not coalesce(v_views_ok, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or both new views are missing or not security_invoker after the migration ran';
  end if;

  -- 12b. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
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

  -- 12c. ABSOLUTE check -- anon/PUBLIC cannot execute _trg_meeting_issue_notify() and cannot SELECT either
  -- new view, independent of 12b.
  if has_function_privilege('anon', 'public._trg_meeting_issue_notify()', 'EXECUTE') then
    v_anon_blocked := false;
    raise exception 'APPLY_REFUSED: post-apply check failed -- public._trg_meeting_issue_notify() is executable by anon/PUBLIC';
  end if;
  if has_table_privilege('anon', 'public.task_minute_totals', 'SELECT') then
    v_anon_blocked := false;
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.task_minute_totals is selectable by anon/PUBLIC';
  end if;
  if has_table_privilege('anon', 'public.person_minute_totals', 'SELECT') then
    v_anon_blocked := false;
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.person_minute_totals is selectable by anon/PUBLIC';
  end if;
  -- informational only (not enforced): `authenticated` should be able to select both views.
  select has_table_privilege('authenticated', 'public.task_minute_totals', 'SELECT')
         and has_table_privilege('authenticated', 'public.person_minute_totals', 'SELECT')
    into v_auth_select;

  -- 12d. the real notifications/meeting_issues/task_logs fingerprint is unchanged from step 7.
  select md5(coalesce((select string_agg(n.id::text || ':' || n.type || ':' || coalesce(n.user_id::text,'-'), ',' order by n.id)
                     from public.notifications n where n.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%'), ''))
         || '|' || md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || coalesce(i.solution,'-'), ',' order by i.id)
                     from public.meeting_issues i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.task_logs l where l.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real notifications/meeting_issues/task_logs fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 13. Every step above passed -- record the one status row.
  insert into pg_temp.huddle_notify_ops_and_task_minute_totals_apply_status (
    migration_version, version_registered, views_exist_and_security_invoker, anon_cannot_access,
    authenticated_can_select_views, newly_leaked_functions,
    data_fingerprint_before, data_fingerprint_after, data_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_views_ok, v_anon_blocked,
    v_auth_select, v_newly_leaked,
    v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.huddle_notify_ops_and_task_minute_totals_apply_status;
