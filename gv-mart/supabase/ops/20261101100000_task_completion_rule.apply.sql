-- GO APPLY script for migration 20261101100000_task_completion_rule.sql (P1a: who may finish a task,
-- PO-close hardening, tasks_update_assign narrowing), commit aba6c61 on integration/p-series.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 18:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- da86f82365ef3efbadfefd7622275877ce048f57ef3e9a6c401d420286818cdb), and that the live rehearsal of this
-- exact migration (rehearsal_20261101100000_task_completion_rule.sql, wrapper sha256
-- 60d12a8b8455dd85e11034a9962360bbf767b81681abec2ace81539e096b4c7a) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic (a RAISE EXCEPTION inside it rolls back everything the block did -- the migration DDL, the
-- schema_migrations row, all of it -- as one unit; reaching the end without raising commits that same
-- unit). Three statements total, run in order in the same session:
--   1. CREATE TEMP TABLE for the status row -- autocommitted on its own, independent of the DO block.
--   2. The DO block itself -- does the work, and on success INSERTs exactly one status row.
--   3. A read-only SELECT * from that temp table -- the thing to look at afterwards.
--
-- Unlike the rehearsal wrapper, THIS SCRIPT IS MEANT TO COMMIT. No embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only (a) creates a brand-new function (guard_task_completion),
-- (b) redefines an existing function (_po_task_completed_marks_paid) via CREATE OR REPLACE, (c) drops and
-- recreates one trigger (aa_guard_task_completion) and (d) drops and recreates one RLS policy
-- (tasks_update_assign). It never issues an UPDATE/INSERT/DELETE against any table's rows. The pre/post
-- fingerprint below (tasks + purchase_orders row-level fingerprint, same formula as the rehearsal) exists
-- purely to prove that holds live, not because any backfill is expected.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd. Refuses immediately if this looks like the
--      wrong database.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 18:00 IST (same hour as every other GO APPLY script -- NOT the 11:00
--      gate that was used for the Step 3 REHEARSAL only).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261101100000, refuse immediately. Re-running this script after a successful apply is always a
--      safe no-op refusal, never a double-apply.
--   4. LIVE-DEFINITION PRE-CHECK A -- public._po_task_completed_marks_paid() redefines an EXISTING function
--      (created by 20260925100100_po_paid_functions.sql). Same GV_PRECHECK_PROBE pattern as the rehearsal:
--      hash the live definition, then inside a sub-block that is always rolled back, apply the pinned
--      pre-P1a text and hash it again -- if the two differ, something else already changed this function
--      live since the rehearsal was approved, and the apply refuses rather than silently building on top of
--      an unreviewed change.
--   5. LIVE-DEFINITION PRE-CHECK B -- the RLS policy tasks_update_assign (created by
--      20260921160000_task_assignment_system.sql) is dropped and recreated by this migration. Same probe
--      pattern, using pg_get_expr(polqual)/pg_get_expr(polwithcheck) instead of pg_get_functiondef since
--      policies have no CREATE OR REPLACE.
--   6. NEW-FUNCTION PRE-CHECK -- public.guard_task_completion() is brand new (nothing by this name existed
--      before; the earlier, unrelated guard was named guard_task_assignee_update and was dropped by
--      20261006200000). This step refuses if it already exists live, the same "must not already exist"
--      posture as the technician_pending_reviews template this script is modeled on.
--   7. REAL-TABLE FINGERPRINT (BEFORE) -- the same tasks+purchase_orders row-level fingerprint the
--      rehearsal used, over REAL (non __TEST_) organisations only.
--   8. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon, as regprocedure signatures, before touching anything -- so step 12b below can tell
--      "pre-existing, unrelated leak" apart from "this migration just introduced a new one".
--   9. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash
--      above.
--   10. RUN        -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   11. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   12. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      12a. guard_task_completion() exists after the migration ran;
--      12b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it against
--          the BEFORE snapshot. Only functions NEWLY present fail this check; a pre-existing, unrelated
--          leak is left alone and reported, not enforced;
--      12c. BOTH guard_task_completion() and _po_task_completed_marks_paid() are not executable by
--          anon/PUBLIC, checked directly (has_function_privilege also reflects any PUBLIC grant, since
--          every role implicitly carries PUBLIC's grants) -- absolute, independent of 12b;
--      12d. the real tasks+purchase_orders fingerprint is unchanged from step 7 -- this migration touches
--          no table rows at all, only function/trigger/policy definitions and their grants.
--   13. On success, INSERT the one status row into pg_temp.task_completion_rule_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at supabase/rollbacks/20261101100000_task_completion_rule.rollback.sql and is
-- run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.task_completion_rule_apply_status;
create temp table task_completion_rule_apply_status (
  migration_version              text,
  version_registered             boolean,
  guard_task_completion_exists   boolean,
  functions_executable_by_anon   boolean,
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
  v_expected_migration_hash  text := 'da86f82365ef3efbadfefd7622275877ce048f57ef3e9a6c401d420286818cdb';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261101100000';
  v_already_registered       boolean;
  v_text                     text;
  v_hash                     text;
  v_live                     text;
  v_orig                     text;
  v_pre_def                  text;
  v_post_def                 text;
  v_anon_exec_guard          boolean;
  v_anon_exec_po             boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p1amig$-- P1 (client list 12-10-2026, item 6 + security audit): who may finish a task, and the paths around it.
-- Design: gv-mart/docs/design-p1-task-security.md
--
--   1. Only the person a task is assigned to can set it done. Master and operation_admin may reassign a task but cannot complete it
--      on someone's behalf. An UNASSIGNED task can be completed by operations (someone must). Re-opening a finished task: the
--      assignee or operations. A task cannot be INSERTED already done for someone else.
--   2. A purchase_order task can be completed only by a master (the role that approves and pays POs, mark_po_paid / approve_purchase_order).
--   3. Closing the PO through its task (_po_task_completed_marks_paid) is now conditional on the same: a signed-in non-master never marks
--      a PO paid by ticking a task. Paths with no signed-in user (service role, scheduled jobs) are unchanged.
--   4. tasks_update_assign: only operations, the assignee or the assigner may update a task (it was: any staff or technician).
--   (current_technician_id() requires is_active: separate migration 20261101110000_current_technician_id_active, P1b.)
--
-- task_status has three values: open, done, rolled ('rolled' is in the enum but nothing in the app or the database writes it today).
-- How the guard treats the transitions:
--   open   -> done    : assignee only (unassigned: operations); purchase_order tasks: master only
--   rolled -> done    : the same as open -> done (any non-done state is finished by the same rule)
--   done   -> open    : the assignee or operations
--   done   -> rolled  : the same as done -> open
--   open   <-> rolled : not a completion, unrestricted by the guard (the update policy still decides who may update the row)
--
-- Exempt from the completion guard (current_user is not authenticated/anon): the service role, SECURITY DEFINER functions
-- (mark_po_paid, advance_recurring_tasks, the escalation and PO-reminder jobs, the rollover RPCs) and any direct owner connection.
--
-- WHY THE EARLIER GUARD WAS DROPPED (20261006190000 -> 20261006200000) and how this one differs: that trigger froze every column except
-- status / due_date for a non-ops assignee, which broke the app's own edit and reassign flow once task assignment (20260921160000)
-- let any user create, edit and reassign tasks. This guard restricts ONLY the status transition to done / back from done and the
-- insert-as-done case; it never looks at title, description, priority, due dates or assignee. The regression tests in
-- tests/task_completion_rule.test.sql assert that an assignee can still edit and reassign their own task.
--
-- Rollback: supabase/rollbacks/20261101100000_task_completion_rule.rollback.sql

-- 1. completion guard --------------------------------------------------------------------------------------------------
create or replace function public.guard_task_completion()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role, SECURITY DEFINER jobs and the owner connection are not subject to this rule
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'done' and new.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: a task cannot be created already finished for someone else';
    end if;
    return new;
  end if;

  if new.status = 'done' and old.status is distinct from 'done' then
    if old.assignee_id is not null then
      if old.assignee_id is distinct from auth.uid() then
        raise exception 'tasks: only the person a task is assigned to can mark it finished';
      end if;
    elsif not public.is_ops_staff() then
      raise exception 'tasks: only operations can finish a task that has no assignee';
    end if;
    -- both the old and the NEW ref_type: changing a task's ref_type in the same update must not slip past the rule
    if (old.ref_type = 'purchase_order' or new.ref_type = 'purchase_order') and not public.is_master() then
      raise exception 'tasks: only a master can finish a purchase-order task';
    end if;
  elsif old.status = 'done' and new.status is distinct from 'done' then
    if old.assignee_id is distinct from auth.uid() and not public.is_ops_staff() then
      raise exception 'tasks: only the assignee or operations can re-open a finished task';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_task_completion() from public, anon, authenticated;

drop trigger if exists aa_guard_task_completion on public.tasks;
create trigger aa_guard_task_completion
  before insert or update on public.tasks
  for each row execute function public.guard_task_completion();

-- 2. closing the PO through its task needs a master (or a system path) -------------------------------------------------
create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    -- a signed-in user who is not a master never marks a PO paid by ticking its task (the guard above already refuses the tick;
    -- this is the second, independent check). No signed-in user = service role / scheduled job: unchanged.
    if auth.uid() is not null and not public.is_master() then
      return new;
    end if;
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;

revoke all on function public._po_task_completed_marks_paid() from public, anon, authenticated;

-- 3. who may update a task ----------------------------------------------------------------------------------------------
drop policy if exists tasks_update_assign on public.tasks;
create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

notify pgrst, 'reload schema';
$p1amig$;
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

  -- 2. GATE -- 18:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 18 then
    raise exception 'APPLY_REFUSED: this script only runs after 18:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied',
      v_migration_version;
  end if;

  -- 4. LIVE-DEFINITION PRE-CHECK A -- public._po_task_completed_marks_paid() must still be its pre-P1a
  -- definition (20260925100100). Probe: hash the live definition, apply the pinned pre-P1a text inside a
  -- sub-block that always rolls back, hash again, compare.
  v_text := $pochk$create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;$pochk$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> '04010cb97582a59808233d2fb09e1e552de294de25398fddd603029df60a0ed3' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (_po_task_completed_marks_paid): %', v_hash;
  end if;
  v_live := md5(pg_get_functiondef('public._po_task_completed_marks_paid()'::regprocedure));
  begin
    execute replace(v_text, E'\r', '');
    v_orig := md5(pg_get_functiondef('public._po_task_completed_marks_paid()'::regprocedure));
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live public._po_task_completed_marks_paid() (md5 %) differs from its pre-P1a definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 5. LIVE-DEFINITION PRE-CHECK B -- the RLS policy tasks_update_assign must still be its pre-P1a
  -- definition (20260921160000). Policies have no CREATE OR REPLACE, so the probe drops and recreates it,
  -- then rolls back the same way.
  v_text := $polchk$create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );$polchk$;
  v_hash := encode(sha256(convert_to(replace(v_text, E'\r', ''), 'UTF8')), 'hex');
  if v_hash <> 'c40c406b744a9a48f7ac20c6878cabdfd512dfeb0affd0963e4e3fffdbeb4348' then
    raise exception 'APPLY_REFUSED: pre-check snippet hash mismatch (tasks_update_assign): %', v_hash;
  end if;
  select md5(pg_get_expr(pol.polqual, pol.polrelid) || '|' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
    into v_live
    from pg_policy pol
    where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_update_assign';
  begin
    drop policy if exists tasks_update_assign on public.tasks;
    execute replace(v_text, E'\r', '');
    select md5(pg_get_expr(pol.polqual, pol.polrelid) || '|' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
      into v_orig
      from pg_policy pol
      where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_update_assign';
    raise exception 'GV_PRECHECK_PROBE';
  exception when others then
    if sqlerrm <> 'GV_PRECHECK_PROBE' then raise; end if;
  end;
  if v_orig is distinct from v_live then
    raise exception 'APPLY_REFUSED: live tasks_update_assign policy (md5 %) differs from its pre-P1a definition (md5 %) -- something else changed it since this script was approved',
      v_live, v_orig;
  end if;

  -- 6. NEW-FUNCTION PRE-CHECK -- public.guard_task_completion() is brand new; refuse if it already exists.
  select pg_get_functiondef(p.oid) into v_pre_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'guard_task_completion';

  if v_pre_def is not null then
    raise exception 'APPLY_REFUSED: public.guard_task_completion() already exists live before this migration ran (expected: does not exist yet) -- live definition: %',
      v_pre_def;
  end if;

  -- 7. REAL-TABLE FINGERPRINT (BEFORE) -- tasks + purchase_orders, REAL organisations only (same formula
  -- the rehearsal used for its baseline).
  select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
                     from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
         || '|' || md5(coalesce((select string_agg(po.id::text || ':' || po.status::text, ',' order by po.id)
                     from public.purchase_orders po where po.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
    into v_fp_before;

  -- 8. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon, as
  -- regprocedure signatures -- a baseline, not an enforcement point.
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
  values (v_migration_version, 'task_completion_rule', array[replace(v_embedded_migration, E'\r', '')]);

  -- 12a. the new function exists
  select pg_get_functiondef(p.oid) into v_post_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'guard_task_completion';

  if v_post_def is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.guard_task_completion() does not exist after the migration ran';
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

  -- 12c. BOTH functions are not executable by anon/PUBLIC -- absolute, independent of 12b.
  select has_function_privilege('anon', 'public.guard_task_completion()', 'EXECUTE') into v_anon_exec_guard;
  if v_anon_exec_guard then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.guard_task_completion() is executable by anon/PUBLIC';
  end if;
  select has_function_privilege('anon', 'public._po_task_completed_marks_paid()', 'EXECUTE') into v_anon_exec_po;
  if v_anon_exec_po then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public._po_task_completed_marks_paid() is executable by anon/PUBLIC';
  end if;

  -- 12d. the real tasks+purchase_orders fingerprint is unchanged -- this migration touches no table rows.
  select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
                     from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
         || '|' || md5(coalesce((select string_agg(po.id::text || ':' || po.status::text, ',' order by po.id)
                     from public.purchase_orders po where po.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real tasks/purchase_orders fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 13. Every step above passed -- record the one status row.
  insert into pg_temp.task_completion_rule_apply_status (
    migration_version, version_registered, guard_task_completion_exists, functions_executable_by_anon,
    newly_leaked_functions, table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, (v_post_def is not null), (v_anon_exec_guard or v_anon_exec_po),
    v_newly_leaked, v_fp_before, v_fp_after,
    (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.task_completion_rule_apply_status;
