-- GO APPLY script for migration 20261115100400_tasks_customer_outstanding_guard.sql
-- Accounts follow-up spec, commit 72b86b90423bda68c25559566b981a920798b750 on feat/accounts-outstanding-followups.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file.
-- The owner (or an authorised operator) runs this by hand, after 11:00 IST, once the release's
-- DB phase (GV_mart\_local_only\reports\release_2026-10-28\release_log.md) shows fully
-- complete, and once an independent reviewer has approved this exact script.
--
-- Structure: one autocommitted CREATE TEMP TABLE for the status row, then ONE DO block (no
-- top-level BEGIN/COMMIT -- a standalone DO block under autocommit is already atomic), then a
-- read-only SELECT from the status table. Re-running this script after a successful apply is
-- always a safe no-op refusal (step 3: already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.tasks_customer_outstanding_guard_apply_status;
create temp table tasks_customer_outstanding_guard_apply_status (
  migration_version text,
  version_registered boolean,
  guard_trigger_exists boolean,
  policy_matches_expected_final_shape boolean,
  newly_leaked_functions text[],
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := 'c791fdc658476f22908a3f213bdcc6584e481de6c910d47cfb1dc67cacef0678';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115100400';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_pre_qual                 text;
  v_post_qual                text;

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature B, step 5 of 5 — hide customer_outstanding
-- tasks from technicians, and block non-master writes of that ref_type.
--
-- Built on the POST-P3 (integration/p-series, 20261103100000) shape of
-- tasks_select_internal, not the current live one (owner's condition 1):
-- P3 narrows `tasks_select_internal` to
--   (is_staff() or current_technician_id() is not null)
--   and (is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
-- This migration's timestamp sorts after P3's, so by the time it runs for
-- real, P3 will already be live (it is part of the same release window
-- that gates this feature's own apply — see DECISIONS.md). The pre-check
-- below refuses to proceed if the live policy text does not match that
-- expected shape, so this can never silently apply against the wrong
-- baseline.
--
-- Technicians never see a customer_outstanding task at all (spec hard
-- rule); every other ref_type, and every is_staff()/is_ops_staff() path,
-- is untouched. INSERT/UPDATE of ref_type='customer_outstanding' is
-- additionally blocked for anyone but master by a trigger (independent of,
-- and stronger than, the existing tasks_insert_assign/tasks_update_assign
-- policies, which are left exactly as-is). DELETE is already is_ops_staff()
-- -only via the untouched tasks_delete_ops policy.

do $precheck$
declare
  v_live_qual text;
  v_normalized text;
begin
  select replace(qual, E'\r', '') into v_live_qual
  from pg_policies
  where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

  if v_live_qual is null then
    raise exception 'tasks_customer_outstanding_guard: tasks_select_internal policy not found';
  end if;

  v_normalized := regexp_replace(v_live_qual, '\s+', ' ', 'g');

  if v_normalized !~ 'is_ops_staff\(\)' or v_normalized !~ 'assignee_id = auth\.uid\(\)' or v_normalized !~ 'assigned_by = auth\.uid\(\)' then
    raise exception 'tasks_customer_outstanding_guard: live tasks_select_internal does not match the expected post-P3 shape (got: %). Apply P1a/P1b/P2/P3 (integration/p-series) first.', v_normalized;
  end if;
end;
$precheck$;

drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or (public.current_technician_id() is not null and ref_type is distinct from 'customer_outstanding'))
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

create or replace function public._guard_customer_outstanding_task_ref()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.ref_type = 'customer_outstanding' and not coalesce(public.is_master(), false) then
    raise exception 'tasks: only master may create or modify a customer-outstanding task';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customer_outstanding_task_ref() from public, anon, authenticated;

drop trigger if exists aaa_guard_customer_outstanding_task_ref on public.tasks;
create trigger aaa_guard_customer_outstanding_task_ref
  before insert or update on public.tasks
  for each row execute function public._guard_customer_outstanding_task_ref();
$migration$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered -- stop, nothing applied', v_migration_version;
  end if;


  -- 4. LIVE-DEFINITION PRE-CHECKS
  if to_regprocedure('public._guard_customer_outstanding_task_ref()') is not null then
    raise exception 'APPLY_REFUSED: public._guard_customer_outstanding_task_ref() already exists before this migration ran';
  end if;
  select replace(regexp_replace(qual, '\s+', ' ', 'g'), '  ', ' ') into v_pre_qual
    from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';
  if v_pre_qual is distinct from '((org_id = current_org_id()) AND (is_staff() OR (current_technician_id() IS NOT NULL)) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))' then
    raise exception 'APPLY_REFUSED: live tasks_select_internal does not match the expected post-P3 shape this migration assumes (got: %). P1a/P1b/P2/P3 (integration/p-series) must be live first.', v_pre_qual;
  end if;

  -- 5. LEAK SNAPSHOT (BEFORE)
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

  -- 6. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'tasks_customer_outstanding_guard', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regprocedure('public._guard_customer_outstanding_task_ref()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard function missing';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard trigger missing';
  end if;
  select replace(regexp_replace(qual, '\s+', ' ', 'g'), '  ', ' ') into v_post_qual
    from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';
  if v_post_qual is distinct from '((org_id = current_org_id()) AND (is_staff() OR ((current_technician_id() IS NOT NULL) AND (ref_type IS DISTINCT FROM 'customer_outstanding'::text))) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))' then
    raise exception 'APPLY_REFUSED: post-apply check failed -- tasks_select_internal does not match the expected final shape (got: %)', v_post_qual;
  end if;
  if has_function_privilege('anon', 'public._guard_customer_outstanding_task_ref()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard function is executable by anon/PUBLIC';
  end if;

  -- 9x. DIFF-BASED leak check -- only NEW anon/PUBLIC-executable functions fail this.
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
  from (select unnest(v_leaked_after) as x except select unnest(v_leaked_before)) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed %% function(s) to PUBLIC/anon: %',
      v_newly_leaked;
  end if;

  -- 9y. real-organisation fingerprint unchanged (identity check, not a no-row-change guarantee --
  -- this migration may add rows elsewhere, but the organisation row itself is never touched).
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.tasks_customer_outstanding_guard_apply_status (migration_version, version_registered, guard_trigger_exists, policy_matches_expected_final_shape, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (exists (select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal)),
    (v_post_qual is not distinct from '((org_id = current_org_id()) AND (is_staff() OR ((current_technician_id() IS NOT NULL) AND (ref_type IS DISTINCT FROM 'customer_outstanding'::text))) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))'),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.tasks_customer_outstanding_guard_apply_status;
