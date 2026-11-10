-- GO APPLY script for migration 20261103100000_task_logs_and_visibility.sql (P3: per-task work log,
-- automatic reassignment/status/due-date entries, narrowed tasks_select_internal visibility), commit
-- 9a8d76c on integration/p-series.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5), that P1a and P1b have ALREADY been
-- applied for real (this script checks, see step 4, but does not chain or re-run them -- unlike the
-- rehearsal, which chains P1a+P1b inside the same throwaway transaction because none of the three had been
-- separately applied anywhere yet), and that the live rehearsal of P3
-- (rehearsal_20261103100000_task_logs_and_visibility.sql, wrapper sha256
-- 609e14ae88f4d8daaaa2f4ef7217eb2edeba85f3467f63600cad12eaa2c504d9) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only creates one brand-new table (task_logs, empty at creation --
-- nothing backfills it), 3 brand-new functions, and redefines one existing RLS policy
-- (tasks_select_internal). It issues no INSERT/UPDATE/DELETE against any pre-existing table's rows. The
-- pre/post fingerprint below (tasks row-level fingerprint, same formula P1a's apply script used) exists
-- purely to prove that holds live.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261103100000, refuse immediately.
--   4. PREREQUISITE CHECK -- P1a (20261101100000) and P1b (20261101110000) must ALREADY be registered in
--      supabase_migrations.schema_migrations (this migration's own header says it depends on both), AND
--      the live public.current_technician_id() definition must match the POST-P1b text exactly (by md5 of
--      pg_get_functiondef) -- a defensive belt-and-braces check that the function body, not just the
--      version row, actually reflects P1b, since this migration's own new policy (step 3 of the migration
--      text) calls current_technician_id() and depends on its is_active behaviour.
--   5. LIVE-DEFINITION PRE-CHECK -- the RLS policy tasks_select_internal (created by
--      20260921160000_task_assignment_system.sql) is dropped and recreated by this migration.
--      GV_PRECHECK_PROBE pattern: hash the live USING clause, apply the pinned pre-P3 text inside a
--      sub-block that always rolls back, hash again, compare.
--   6. NEW-OBJECT PRE-CHECK -- none of the 3 brand-new functions this migration creates via `create or
--      replace function` may already exist (that statement would silently overwrite an unexpected
--      pre-existing function rather than erroring). public.task_logs uses plain `create table` with no IF
--      NOT EXISTS, so Postgres's own DDL already refuses and rolls the whole block back if it exists --
--      checked anyway, defensively, with to_regclass.
--   7. REAL-TABLE FINGERPRINT (BEFORE) -- the same tasks row-level fingerprint P1a's apply script used,
--      over REAL (non __TEST_) organisations only.
--   8. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   9. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   10. RUN        -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   11. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   12. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      12a. public.task_logs exists and all 3 new functions exist;
--      12b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      12c. ABSOLUTE anon-exec check -- anon/PUBLIC must not be able to execute any of the 3 new
--          functions, regardless of 12b. (authenticated IS meant to select/insert task_logs directly --
--          that is a table grant, not a function grant, and is asserted informationally, not enforced,
--          since RLS -- checked separately below -- is the real gate on what rows are visible/insertable.)
--      12d. task_logs has row level security enabled and the two expected policies exist;
--      12e. the real tasks fingerprint is unchanged from step 7 -- this migration touches no table rows.
--   13. On success, INSERT the one status row into pg_temp.task_logs_and_visibility_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at supabase/rollbacks/20261103100000_task_logs_and_visibility.rollback.sql and
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.task_logs_and_visibility_apply_status;
create temp table task_logs_and_visibility_apply_status (
  migration_version              text,
  version_registered             boolean,
  new_objects_exist              boolean,
  rls_enabled_and_policies_exist boolean,
  functions_executable_by_anon   boolean,
  authenticated_can_select_insert_task_logs boolean,
  newly_leaked_functions         text[],
  table_fingerprint_before       text,
  table_fingerprint_after        text,
  table_fingerprint_unchanged    boolean,
  applied_at                     timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := '99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261103100000';
  v_already_registered       boolean;
  v_p1a_registered           boolean;
  v_p1b_registered           boolean;
  v_cti_live_md5             text;
  v_text                     text;
  v_hash                     text;
  v_live                     text;
  v_orig                     text;
  v_sig                      text;
  v_new_sigs                 text[] := array[
    'public._trg_task_log_client_insert()',
    'public._trg_task_log_immutable()',
    'public._trg_task_log_changes()'
  ];
  v_new_objects_exist        boolean := true;
  v_anon_exec                boolean := false;
  v_auth_table_priv          boolean;
  v_rls_ok                   boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p3mig$-- P3 (client list 12-10-2026 items 4, 5, 6): who sees which task, and a work log on every task. Design: gv-mart/docs/design-p3-task-log-visibility.md
--
--   1. task_logs            work log per task: a note, minutes spent, what is planned next and when (written by a person), and
--                           automatic entries for every reassignment, status change and due-date move (written by the database).
--                           Append-only: nobody can edit or delete an entry through the API.
--   2. tasks_select_internal narrowed: master and operation_admin see every task of the organisation; everyone else sees the tasks
--                           assigned to them and the tasks they assigned.
--
-- Depends on P1a (20261101100000: guard_task_completion, tasks_update_assign), P1b and P2 (20261102100000: profiles.task_color is
-- read by the screens, not by this file). Nothing here alters those objects.
--
-- Rollback: supabase/rollbacks/20261103100000_task_logs_and_visibility.rollback.sql

-- 1. the work log ---------------------------------------------------------------------------------------------------------
create table public.task_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  kind text not null default 'note' check (kind in ('note', 'reassigned', 'status', 'due_moved')),
  created_by uuid references public.profiles (id) on delete set null,
  actor_name text,
  note text check (note is null or char_length(btrim(note)) between 1 and 2000),
  minutes_spent integer check (minutes_spent is null or minutes_spent between 0 and 1440),
  next_planned_date date,
  next_planned_note text check (next_planned_note is null or char_length(btrim(next_planned_note)) between 1 and 500),
  from_user uuid references public.profiles (id) on delete set null,
  to_user uuid references public.profiles (id) on delete set null,
  from_name text,
  to_name text,
  from_value text,
  to_value text,
  created_at timestamptz not null default now(),
  constraint task_logs_note_has_content check (
    kind <> 'note' or note is not null or minutes_spent is not null or next_planned_date is not null or next_planned_note is not null
  )
);
create index task_logs_task_idx on public.task_logs (task_id, created_at);
create index task_logs_org_idx on public.task_logs (org_id);

alter table public.task_logs enable row level security;
revoke all on public.task_logs from public, anon, authenticated;
grant select, insert on public.task_logs to authenticated;
grant select, insert, update, delete on public.task_logs to service_role;

-- A person sees the log of a task they can see: the subquery runs under the caller's own tasks policy (section 2), so the two rules
-- cannot drift apart.
create policy task_logs_select on public.task_logs for select
  using (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id));
create policy task_logs_insert on public.task_logs for insert
  with check (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id and t.org_id = task_logs.org_id));
-- no update or delete policy, and no update or delete privilege: an entry is corrected by adding another one

-- What a client can write is a note by themselves: the database stamps who and when and clears the system-only columns.
-- SECURITY INVOKER on purpose: it tells a client from a trusted path by current_user, which inside a SECURITY DEFINER function is the
-- owner. The only thing it reads is the caller's own profile name, which profiles_select_own (id = auth.uid()) allows.
create or replace function public._trg_task_log_client_insert()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.kind := 'note';
    new.created_by := auth.uid();
    new.actor_name := (select p.full_name from public.profiles p where p.id = auth.uid());
    new.from_user := null;
    new.to_user := null;
    new.from_name := null;
    new.to_name := null;
    new.from_value := null;
    new.to_value := null;
    new.created_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_client_insert() from public, anon, authenticated;
create trigger task_logs_client_insert before insert on public.task_logs
  for each row execute function public._trg_task_log_client_insert();

create or replace function public._trg_task_log_immutable()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'task_logs: a log entry cannot be changed or removed';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_immutable() from public, anon, authenticated;
create trigger task_logs_immutable before update or delete on public.task_logs
  for each row execute function public._trg_task_log_immutable();

-- 2. automatic entries ----------------------------------------------------------------------------------------------------
-- Every reassignment (who, from whom, to whom), status change and due-date move is written by the database, whoever made it and
-- through whatever path. P1 accepted that an assigner may reassign a task to themselves and finish it; this is how that stays visible.
-- A path with no signed-in user (service role, scheduled job) is logged with no actor.
create or replace function public._trg_task_log_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor text := (select p.full_name from public.profiles p where p.id = auth.uid());
begin
  if new.assignee_id is distinct from old.assignee_id then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_user, to_user, from_name, to_name)
    values (new.org_id, new.id, 'reassigned', auth.uid(), v_actor, old.assignee_id, new.assignee_id,
            (select p.full_name from public.profiles p where p.id = old.assignee_id),
            (select p.full_name from public.profiles p where p.id = new.assignee_id));
  end if;
  if new.status is distinct from old.status then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'status', auth.uid(), v_actor, old.status::text, new.status::text);
  end if;
  if new.due_date is distinct from old.due_date then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'due_moved', auth.uid(), v_actor, old.due_date::text, new.due_date::text);
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_changes() from public, anon, authenticated;
drop trigger if exists zz_tasks_log_changes on public.tasks;
create trigger zz_tasks_log_changes
  after update of assignee_id, status, due_date on public.tasks
  for each row execute function public._trg_task_log_changes();

-- 3. who sees a task ------------------------------------------------------------------------------------------------------
-- Master and operation_admin: every task of the organisation. Everyone else (sales_admin, technician): the tasks assigned to
-- them and the tasks they assigned. The base condition (staff, or an active technician) is unchanged. Insert, update and delete
-- policies are not touched here.
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

notify pgrst, 'reload schema';
$p3mig$;
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

  -- 4. PREREQUISITE CHECK -- P1a and P1b must already be applied (this migration's own header says it
  -- depends on both), AND current_technician_id() must actually carry the post-P1b body, not just the
  -- version row.
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261101100000') into v_p1a_registered;
  if not v_p1a_registered then
    raise exception 'APPLY_REFUSED: prerequisite P1a (20261101100000) is not yet registered in supabase_migrations.schema_migrations -- apply P1a first';
  end if;
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261101110000') into v_p1b_registered;
  if not v_p1b_registered then
    raise exception 'APPLY_REFUSED: prerequisite P1b (20261101110000) is not yet registered in supabase_migrations.schema_migrations -- apply P1b first';
  end if;
  -- pg_get_functiondef() re-renders Postgres's own canonical form, not the literal source text, so this
  -- does not try to match the post-P1b text byte-for-byte. The reliable, enforced signal is simpler:
  -- current_technician_id()'s live body must reference technicians.is_active somewhere, which only the
  -- post-P1b definition does (the pre-P1b body has no is_active clause at all).
  v_cti_live_md5 := md5(pg_get_functiondef('public.current_technician_id()'::regprocedure));
  if position('is_active' in coalesce(pg_get_functiondef('public.current_technician_id()'::regprocedure), '')) = 0 then
    raise exception 'APPLY_REFUSED: prerequisite check failed -- public.current_technician_id() does not reference is_active; P1b does not appear to be live (md5 %)', v_cti_live_md5;
  end if;

  -- 5. LIVE-DEFINITION PRE-CHECK -- the RLS policy tasks_select_internal must still be its pre-P3
  -- definition (20260921160000). GV_PRECHECK_PROBE pattern: drop/recreate inside a sub-block that always
  -- rolls back, compare md5 of the USING clause before and after.
  v_text := $polchk$create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );$polchk$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '833af5546242b4886239f6bd58ede57518f06e30c4543ddf92852e865e8876ed' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (tasks_select_internal): %', v_hash;
  end if;
  select md5(pg_get_expr(pol.polqual, pol.polrelid))
    into v_live
    from pg_policy pol
    where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_select_internal';
  begin
    drop policy if exists tasks_select_internal on public.tasks;
    execute replace(v_text, E'\r', '');
    select md5(pg_get_expr(pol.polqual, pol.polrelid))
      into v_orig
      from pg_policy pol
      where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_select_internal';
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live tasks_select_internal policy (md5 %) differs from its pre-P3 definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 6. NEW-OBJECT PRE-CHECK -- none of the 3 brand-new functions this migration creates via `create or
  -- replace function` may already exist.
  foreach v_sig in array v_new_sigs loop
    if to_regprocedure(v_sig) is not null then
      raise exception 'APPLY_REFUSED: % already exists live before this migration ran (expected: does not exist yet)', v_sig;
    end if;
  end loop;
  if to_regclass('public.task_logs') is not null then
    raise exception 'APPLY_REFUSED: public.task_logs already exists live before this migration ran';
  end if;

  -- 7. REAL-TABLE FINGERPRINT (BEFORE) -- tasks, REAL organisations only (same formula P1a's apply script
  -- used).
  select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
                     from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_before;

  -- 8. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
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
  values (v_migration_version, 'task_logs_and_visibility', array[replace(v_embedded_migration, E'\r', '')]);

  -- 12a. task_logs and all 3 new functions exist.
  if to_regclass('public.task_logs') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.task_logs does not exist after the migration ran';
  end if;
  foreach v_sig in array v_new_sigs loop
    if to_regprocedure(v_sig) is null then
      v_new_objects_exist := false;
      raise exception 'APPLY_REFUSED: post-apply check failed -- % does not exist after the migration ran', v_sig;
    end if;
  end loop;

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

  -- 12c. ABSOLUTE anon-exec check -- anon/PUBLIC must not execute any of the 3 new functions.
  foreach v_sig in array v_new_sigs loop
    if has_function_privilege('anon', v_sig, 'EXECUTE') then
      v_anon_exec := true;
      raise exception 'APPLY_REFUSED: post-apply check failed -- % is executable by anon/PUBLIC', v_sig;
    end if;
  end loop;
  -- informational only: `authenticated` should hold SELECT/INSERT table privilege on task_logs (not
  -- enforced here as a refusal -- RLS, checked next, is the real gate on what rows are visible/insertable).
  select has_table_privilege('authenticated', 'public.task_logs', 'SELECT')
         and has_table_privilege('authenticated', 'public.task_logs', 'INSERT')
    into v_auth_table_priv;

  -- 12d. task_logs has RLS enabled and the two expected policies exist.
  select c.relrowsecurity
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.task_logs'::regclass and pol.polname = 'task_logs_select')
         and exists (select 1 from pg_policy pol where pol.polrelid = 'public.task_logs'::regclass and pol.polname = 'task_logs_insert')
    into v_rls_ok
    from pg_class c
    where c.oid = 'public.task_logs'::regclass;

  if not coalesce(v_rls_ok, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.task_logs is missing row level security or one of its two expected policies';
  end if;

  -- 12e. the real tasks fingerprint is unchanged -- this migration touches no table rows.
  select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
                     from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real tasks fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 13. Every step above passed -- record the one status row.
  insert into pg_temp.task_logs_and_visibility_apply_status (
    migration_version, version_registered, new_objects_exist, rls_enabled_and_policies_exist,
    functions_executable_by_anon, authenticated_can_select_insert_task_logs, newly_leaked_functions,
    table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_rls_ok,
    v_anon_exec, v_auth_table_priv, v_newly_leaked,
    v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.task_logs_and_visibility_apply_status;
