-- DRYRUN copy of 20261204140000_customer_needs_review_notify.apply.sql -- byte-identical
-- except for one added line at the very end: an unconditional RAISE after every check has
-- already passed, forcing the whole statement to roll back. Run this first; only run the real
-- .apply.sql after this comes back DRYRUN_OK.
--
-- GO APPLY script for 20261204140000_customer_needs_review_notify.sql (the
-- customers.needs_review -> task + notification trigger). branch feat/urgent-duplicate-customer-flow.
--
-- Full rehearsal (18/18 checks: one task+one role-broadcast notification per flagged customer,
-- assigned to the oldest active master, dedup on re-save and on resolve-then-reflag, a second
-- independent customer gets its own task, an unrelated column update never fires it, no direct
-- call possible by any role, no money-table writes) ran clean, fully rolled back -- see
-- _local_only/reports/dup_contacts/needs_review_rehearsal_20261204140000.sql.out.txt.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. ALREADY-REGISTERED CHECK -- refuses if 20261204140000 is already registered.
--   3. NEW-OBJECT PRE-CHECK -- public._notify_customer_needs_review() and the
--                           customers_needs_review_notify trigger must not already exist.
--   4. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers,
--                           leads, tasks and notifications, over REAL organisations only. This
--                           migration writes no data at apply time (DDL only, the trigger only
--                           fires on a FUTURE customers.needs_review change) -- all four must be
--                           identical after.
--   5. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
--   6. PIN              -- CR-tolerant sha256 of the embedded migration text must equal the
--                           pinned hash of the committed file.
--   7. RUN              -- EXECUTE the migration, verbatim (CR-tolerant).
--   8. REGISTER         -- INSERT the version row into supabase_migrations.schema_migrations,
--                           in the same transaction as the migration itself.
--   9. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      9a. the function and the trigger both exist, trigger fires AFTER INSERT OR UPDATE OF
--          needs_review on customers, calling this exact function;
--      9b. grants: anon/public/authenticated cannot execute the function;
--      9c. DIFF-BASED leak check against the BEFORE snapshot -- 0 new anon/PUBLIC-executable
--          functions expected (the function explicitly revokes public/anon/authenticated);
--      9d. ABSOLUTE check -- anon cannot execute the function, independent of 9c;
--      9e. the real customers/leads/tasks/notifications fingerprints are all unchanged from
--          step 4 (this migration is pure DDL -- it writes nothing itself).
--   10. On success, INSERT the one status row into pg_temp.needs_review_apply_status.
--
-- Rollback: supabase/rollbacks/20261204140000_customer_needs_review_notify.rollback.sql
-- (drop trigger, drop function, delete the schema_migrations row -- exercised inside the
-- rehearsal's own sandboxed transaction before this script was written).

drop table if exists pg_temp.needs_review_apply_status;
create temp table needs_review_apply_status (
  version_registered            text,
  function_exists                boolean,
  trigger_exists                 boolean,
  grants_correct                 boolean,
  functions_executable_by_anon   boolean,
  newly_leaked_functions         text[],
  customers_fingerprint_unchanged      boolean,
  leads_fingerprint_unchanged           boolean,
  tasks_fingerprint_unchanged           boolean,
  notifications_fingerprint_unchanged   boolean,
  applied_at                     timestamptz
);

do $apply$
declare
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
  v_expected_migration_hash text := '376323642a3935dfe5c31fe33d68323ae31d0bf12184b2bd28333deea6752e67';
  v_actual_hash text;
  v_already_registered boolean;
  v_function_exists boolean := false;
  v_trigger_exists boolean := false;
  v_grants_correct boolean := false;
  v_anon_exec boolean := false;
  v_leaked_before text[];
  v_leaked_after text[];
  v_newly_leaked text[];
  v_cust_count_before bigint; v_cust_md5_before text;
  v_cust_count_after bigint; v_cust_md5_after text;
  v_leads_count_before bigint; v_leads_md5_before text;
  v_leads_count_after bigint; v_leads_md5_after text;
  v_tasks_count_before bigint; v_tasks_md5_before text;
  v_tasks_count_after bigint; v_tasks_md5_after text;
  v_notif_count_before bigint; v_notif_md5_before text;
  v_notif_count_after bigint; v_notif_md5_after text;
  v_migration_text text;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST\_%' escape '\'
  order by o.created_at asc, o.id asc
  limit 1;
  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. ALREADY-REGISTERED CHECK
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261204140000') into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: 20261204140000 is already registered in supabase_migrations.schema_migrations -- stop, nothing applied';
  end if;

  -- 3. NEW-OBJECT PRE-CHECK
  if to_regprocedure('public._notify_customer_needs_review()') is not null then
    raise exception 'APPLY_REFUSED: public._notify_customer_needs_review() already exists live before this migration ran';
  end if;
  if exists (select 1 from information_schema.triggers where event_object_table = 'customers' and trigger_name = 'customers_needs_review_notify') then
    raise exception 'APPLY_REFUSED: customers_needs_review_notify trigger already exists live before this migration ran';
  end if;

  -- 4. REAL-TABLE FINGERPRINT (BEFORE)
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_before, v_cust_md5_before
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_leads_count_before, v_leads_md5_before
  from public.leads
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_tasks_count_before, v_tasks_md5_before
  from public.tasks
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_notif_count_before, v_notif_md5_before
  from public.notifications
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

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

  -- 6. PIN
  v_migration_text := $migration$-- Item 5(c) (urgent task list, owner guardrails 2026-11-03): when customer_auto_onboard()
-- or the phone-OTP merge-on-verify RPC flags a newly-created customers row needs_review = true
-- (a sign-in matched more than one existing record, or one already linked elsewhere, and the
-- system deliberately did not guess), staff need to find out and act on it. Today nothing does
-- that -- needs_review is only visible via a badge if a master happens to browse the admin
-- Customers list (CustomersListPage.tsx) and filters for it.
--
-- This migration adds exactly one thing: a trigger on public.customers that, the moment a row's
-- needs_review transitions from false/absent to true, creates ONE "Customer needs account
-- review" task (assigned to one active master) and ONE in-app notification (broadcast to all
-- active masters, same role-targeted-notification convention as every other
-- `insert into public.notifications (org_id, role, ...)` call in this project -- see e.g.
-- 20260702100100_sales_phase5_functions.sql:230-234).
--
-- GUARDRAILS (owner, 2026-11-03), all satisfied by this migration:
--   (2) Deduplicated: the dedup check mirrors the established convention
--       (20261204100000_sync_outstanding_tasks.sql:87-90 -- `where ref_type = X and ref_id = Y
--       and status = 'open'`) -- an open task already exists for this customer -> skip, so a
--       repeat sign-in (which re-runs customer_auto_onboard's idempotent short-circuit and
--       never re-flags an already-flagged row anyway, but belt-and-suspenders) never creates a
--       second task. One task per customer, not one per event.
--       Assigned to ONE master (oldest active master in the org, same
--       "no explicit assignee -> fall back to the oldest active master" shape as
--       20261204100000_sync_outstanding_tasks.sql:40-46's v_owner resolution) -- not all of
--       them, so there's a single clear owner. The notification goes to all active masters
--       (role-broadcast), so no master is left unaware even though only one is assigned the work.
--   (3) Nothing is ever sent to the customer: this trigger touches only public.tasks and
--       public.notifications -- no WhatsApp/SMS/email, no row in wa_outbox or any
--       customer-facing table. wa_test_mode_enabled is untouched.
--   (4) No trigger that touches money tables or writes beyond the notification and task rows:
--       this function's only two statements are the two inserts described above -- nothing
--       else is read-write (the master lookup and the dedup check are read-only selects).
--
-- Trigger fires on the SAME WHEN condition this project already uses to detect a boolean flag's
-- false->true transition on customers (`customers_is_test_cascade`, 20261016110000:
-- `after insert or update of is_test, mobile`) -- here, `after insert or update of needs_review`,
-- scoped further by a `when (new.needs_review)` clause so the trigger function is never even
-- invoked on the (overwhelmingly common) non-flagged path.
create or replace function public._notify_customer_needs_review()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_assignee uuid;
  v_already_open boolean;
begin
  -- Only a real transition into needs_review=true -- an UPDATE that re-saves an already-true
  -- row (e.g. a later, unrelated column edit) must not re-fire.
  if tg_op = 'UPDATE' and old.needs_review then
    return new;
  end if;

  select exists(
    select 1 from public.tasks
    where ref_type = 'customer_needs_review' and ref_id = new.id and status = 'open'
  ) into v_already_open;
  if v_already_open then
    return new;
  end if;

  select id into v_assignee
  from public.profiles
  where org_id = new.org_id and role = 'master' and is_active
  order by created_at asc
  limit 1;

  if v_assignee is not null then
    insert into public.tasks (org_id, assignee_id, title, source, ref_type, ref_id)
    values (new.org_id, v_assignee, 'Customer needs account review', 'system', 'customer_needs_review', new.id);
  end if;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'master', 'customer_needs_review', 'Customer needs account review',
    'A new sign-in matched existing records and needs a master to review.', new.id
  );

  return new;
end;
$function$;

create trigger customers_needs_review_notify
after insert or update of needs_review on public.customers
for each row
when (new.needs_review)
execute function public._notify_customer_needs_review();

revoke all on function public._notify_customer_needs_review() from public, anon, authenticated;
$migration$;

  v_actual_hash := encode(sha256(convert_to(replace(v_migration_text, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_hash;
  end if;

  -- 7. RUN
  execute replace(v_migration_text, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261204140000', 'customer_needs_review_notify', array[replace(v_migration_text, E'\r', '')]);

  -- 9a. function and trigger exist.
  v_function_exists := to_regprocedure('public._notify_customer_needs_review()') is not null;
  if not v_function_exists then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public._notify_customer_needs_review() is missing after the migration ran';
  end if;
  v_trigger_exists := exists (
    select 1 from information_schema.triggers
    where event_object_table = 'customers' and trigger_name = 'customers_needs_review_notify'
      and action_timing = 'AFTER' and action_statement = 'EXECUTE FUNCTION _notify_customer_needs_review()'
  );
  if not v_trigger_exists then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customers_needs_review_notify trigger is missing or not wired to the expected function after the migration ran';
  end if;

  -- 9b. grants.
  v_grants_correct :=
    (not has_function_privilege('anon', 'public._notify_customer_needs_review()', 'EXECUTE'))
    and (not has_function_privilege('public', 'public._notify_customer_needs_review()', 'EXECUTE'))
    and (not has_function_privilege('authenticated', 'public._notify_customer_needs_review()', 'EXECUTE'));
  if not v_grants_correct then
    raise exception 'APPLY_REFUSED: post-apply check failed -- EXECUTE on _notify_customer_needs_review() is not fully revoked from anon/public/authenticated';
  end if;

  -- 9c. DIFF-BASED leak check.
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon: %', array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 9d. ABSOLUTE check.
  if has_function_privilege('anon', 'public._notify_customer_needs_review()', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- the function is executable by anon';
  end if;

  -- 9e. real fingerprints unchanged (this migration is pure DDL -- it writes no data itself).
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_after, v_cust_md5_after
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_leads_count_after, v_leads_md5_after
  from public.leads
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_tasks_count_after, v_tasks_md5_after
  from public.tasks
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_notif_count_after, v_notif_md5_after
  from public.notifications
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  if v_cust_count_after is distinct from v_cust_count_before or v_cust_md5_after is distinct from v_cust_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real customers fingerprint changed (count before % after %, md5 before % after %)', v_cust_count_before, v_cust_count_after, v_cust_md5_before, v_cust_md5_after;
  end if;
  if v_leads_count_after is distinct from v_leads_count_before or v_leads_md5_after is distinct from v_leads_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real leads fingerprint changed (count before % after %, md5 before % after %)', v_leads_count_before, v_leads_count_after, v_leads_md5_before, v_leads_md5_after;
  end if;
  if v_tasks_count_after is distinct from v_tasks_count_before or v_tasks_md5_after is distinct from v_tasks_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real tasks fingerprint changed (count before % after %, md5 before % after %)', v_tasks_count_before, v_tasks_count_after, v_tasks_md5_before, v_tasks_md5_after;
  end if;
  if v_notif_count_after is distinct from v_notif_count_before or v_notif_md5_after is distinct from v_notif_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real notifications fingerprint changed (count before % after %, md5 before % after %)', v_notif_count_before, v_notif_count_after, v_notif_md5_before, v_notif_md5_after;
  end if;

  -- 10. Every step above passed.
  insert into pg_temp.needs_review_apply_status (
    version_registered, function_exists, trigger_exists, grants_correct,
    functions_executable_by_anon, newly_leaked_functions,
    customers_fingerprint_unchanged, leads_fingerprint_unchanged,
    tasks_fingerprint_unchanged, notifications_fingerprint_unchanged, applied_at
  )
  values (
    '20261204140000', v_function_exists, v_trigger_exists, v_grants_correct,
    v_anon_exec, v_newly_leaked,
    (v_cust_count_after = v_cust_count_before and v_cust_md5_after = v_cust_md5_before),
    (v_leads_count_after = v_leads_count_before and v_leads_md5_after = v_leads_md5_before),
    (v_tasks_count_after = v_tasks_count_before and v_tasks_md5_after = v_tasks_md5_before),
    (v_notif_count_after = v_notif_count_before and v_notif_md5_after = v_notif_md5_before),
    now()
  );

  -- DRYRUN ONLY: every check above passed -- force a rollback so nothing from this run
  -- persists, including the schema_migrations row and the new function/trigger.
  -- This is the one and only difference from the real apply script.
  raise exception 'DRYRUN_OK: all apply-script checks passed; nothing was committed (forced rollback)';
end
$apply$;

select * from pg_temp.needs_review_apply_status;
