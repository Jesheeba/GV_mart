-- GO APPLY script for migration 20261112100000_technician_pending_reviews.sql
-- (public.list_technician_pending_reviews()), commit 81621b7a5512deb533dab98db961e631ae53ec40 on
-- feat/technician-pending-reviews.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 55b33aaf1d276984e3873b46a8e413393b87dbe3c094ddef67483d07a8c408a3).
--
-- Structure (2026-11-15 revision): no top-level BEGIN;/COMMIT; -- a single standalone DO block run under
-- autocommit is already atomic (a RAISE EXCEPTION inside it rolls back everything the block did -- the
-- migration DDL, the schema_migrations row, all of it -- as one unit; reaching the end of the block
-- without raising commits that same unit). Three statements total, run in order in the same session:
--   1. CREATE TEMP TABLE for the status row -- a separate, already-autocommitted statement, so the table
--      exists regardless of whether the DO block below succeeds or fails. On failure the DO block's own
--      INSERT into it never ran (rolled back with everything else), so the table is simply empty --
--      itself a correct, queryable signal that nothing was applied.
--   2. The DO block itself -- does the actual work, and on success INSERTs exactly one status row.
--   3. A read-only SELECT * from that temp table -- the thing to actually look at afterwards. Success is
--      proven by this query returning one row with the expected values, never by a RAISE NOTICE (which a
--      client can swallow or scroll past).
--
-- Unlike the rehearsal wrapper (supabase/ops/technician_pending_reviews.rehearsal.sql), THIS SCRIPT IS
-- MEANT TO COMMIT. There is no embedded test and no forced closing RAISE.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK   -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint. Refuses immediately if this looks like the wrong database.
--   1. LOCK        -- lock_timeout = 5s for this transaction only.
--   2. GATE        -- refuses before 11:00 IST (same convention, and now the same hour, as the
--      rehearsals).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261112100000, refuse immediately. Re-running this script after a successful apply is always a
--      safe no-op refusal, never a double-apply.
--   4. LIVE-DEFINITION PRE-CHECK -- this migration only ever CREATEs public.list_technician_pending_reviews()
--      for the first time; it does not replace an existing different body. The rehearsal never pinned a
--      "live before" definition for it (the rehearsal's own real-row fingerprint only covers table DATA,
--      not function DEFINITIONS), so this script pins the only definition consistent with that rehearsal
--      run and with this migration's own design: NULL, i.e. the function must not already exist live.
--   5. LEAK SNAPSHOT (BEFORE) -- capture the full list of public-schema functions already executable by
--      PUBLIC/anon, as an array of regprocedure signatures, before touching anything. This exists purely
--      so step 8b below can tell "pre-existing, unrelated leak" apart from "this migration just
--      introduced a new one" -- an old unrelated leaky function must never block this apply.
--   6. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash
--      above (same CR-tolerance fix as the rehearsal wrapper, commit 81621b7a).
--   7. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   8. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself, so the two can never go out of sync.
--   9. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      9a. the new function exists;
--      9b. DIFF-BASED leak check -- recompute the same PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot (step 5). Only functions NEWLY present in that list fail this
--          check; anything that was already leaky before this migration ran is left alone and reported,
--          not enforced, so an old unrelated function can never block this apply.
--      9c. the new function specifically is not executable by anon/PUBLIC, checked directly
--          (has_function_privilege also reflects any grant made to the PUBLIC pseudo-role, since every
--          role implicitly carries PUBLIC's grants, so this one check covers both anon and PUBLIC) --
--          this is an absolute requirement regardless of what 9b finds;
--      9d. the real organisation's fingerprint is unchanged (this migration touches no table ROWS at
--          all -- only a function definition and its grants -- so this must be byte-identical to the
--          value taken in step 0).
--   10. On success, INSERT the one status row into pg_temp.technician_pending_reviews_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at supabase/rollbacks/20261112100000_technician_pending_reviews.rollback.sql
-- and is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.technician_pending_reviews_apply_status;
create temp table technician_pending_reviews_apply_status (
  migration_version            text,
  version_registered            boolean,
  function_exists                boolean,
  function_executable_by_anon    boolean,
  newly_leaked_functions         text[],
  org_fingerprint_before         text,
  org_fingerprint_after          text,
  org_fingerprint_unchanged      boolean,
  applied_at                     timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '55b33aaf1d276984e3873b46a8e413393b87dbe3c094ddef67483d07a8c408a3';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261112100000';
  v_already_registered       boolean;
  v_pre_def                  text;
  v_post_def                 text;
  v_anon_exec                boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_embedded_migration       text := $migration$-- Technician "Pending reviews" list (2026-11-12).
--
-- Display-only feature: a technician's own dashboard shows customers from HIS OWN completed visits
-- (service_visits.technician_id = his technicians.id, timer_end not null -- the same "completed" test
-- get_technician_public_stats already uses) who have NOT yet left a rating (no row in public.ratings
-- for that visit, per ratings.visit_id's own unique-per-visit constraint). Nothing is sent, emailed or
-- messaged from this -- it is a read-only follow-up list for the technician to act on in person.
--
-- Two additional filters (2026-11-13 review):
--   * Test customers excluded via `not c.is_test` -- this codebase already flags throwaway/demo
--     customers (`customers.is_test`, 20261016110000_test_customer_flag.sql) and keeps them out of
--     real figures everywhere else (incentives, reports); this list is no exception. Deliberately NOT
--     `public.is_test_customer(c.id)` (that migration's own helper): it is `security definer` but its
--     EXECUTE grant is `service_role` only (20261016110000_test_customer_flag.sql:39-41) -- calling it
--     from this function, which is `security invoker` on purpose (see above), would raise "permission
--     denied" for every real technician, since the invoker here is `authenticated`, not service_role.
--     Reading `c.is_test` directly off the already-joined, already-RLS-visible `customers` row needs no
--     extra grant and has identical semantics.
--   * Only visits completed in the last 60 days -- `sv.timer_end` compared against IST midnight 60
--     days before today's IST date (Asia/Kolkata), so the cutoff is a calendar-day boundary in the
--     technician's own timezone, not a bare 1440-hour window that would silently drift with UTC/IST
--     offset or daylight-adjacent edge cases (IST itself has no DST, but every other date computation
--     in this codebase that matters to a person -- incentive months, shift-end prompts -- is anchored
--     to Asia/Kolkata for the same reason: calendar days must mean the same thing the technician sees
--     on his own clock).
--
-- Strict ownership (technician B must never see technician A's customers) is enforced at the data layer,
-- not just hidden in the UI, two ways at once:
--   1. SECURITY INVOKER: this function carries no elevated privilege of its own -- every table it reads
--      (service_visits, service_tickets, customers, ratings) is read under the CALLER's own role and is
--      already subject to that table's real RLS (service_visits_write_own_technician restricts SELECT on
--      service_visits to technician_id = current_technician_id(); customers_select_own_technician and
--      service_tickets_select_own_technician/_customer_history_technician likewise scope the join tables --
--      see 20260701091300_rls.sql, 20260704120000_technician_customer_address_rls.sql,
--      20260723120000_technician_customer_history_rls.sql). A technician cannot make this function return
--      another technician's row even by bypassing the app, because the underlying SELECT privilege simply
--      isn't there for that row.
--   2. An explicit `sv.technician_id = public.current_technician_id()` filter in the function body itself,
--      as defense in depth on top of (1) and so a non-technician caller (current_technician_id() = null)
--      always gets zero rows rather than relying on RLS alone.
-- Every column referenced inside the query is table-qualified (sv./t./c./r.) to avoid the exact class of
-- ambiguous-column bug a bare `technician_id` or `visit_id` could introduce once this function is read
-- alongside sibling tables that share those column names.

-- The caller gets only name, job type and completion date -- never the customer's phone number.
-- This is a display-only follow-up list (no call/WhatsApp action anywhere downstream), so the
-- mobile column is deliberately left out of the result rather than fetched and merely hidden by
-- the UI -- the same "don't expose what the screen must not show" posture as this project's other
-- technician-facing reads.
create or replace function public.list_technician_pending_reviews()
returns table (
  visit_id uuid,
  ticket_id uuid,
  customer_id uuid,
  customer_name text,
  complaint text,
  visit_completed_at timestamptz
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select
    sv.id as visit_id,
    sv.ticket_id,
    t.customer_id,
    c.name as customer_name,
    t.name_of_complaint as complaint,
    sv.timer_end as visit_completed_at
  from public.service_visits sv
  join public.service_tickets t on t.id = sv.ticket_id
  join public.customers c on c.id = t.customer_id
  where sv.technician_id = public.current_technician_id()
    and sv.timer_end is not null
    and sv.timer_end >= (((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp at time zone 'Asia/Kolkata')
    and not c.is_test
    and not exists (
      select 1 from public.ratings r where r.visit_id = sv.id
    )
  order by sv.timer_end desc
$$;

revoke all on function public.list_technician_pending_reviews() from public, anon, authenticated;
grant execute on function public.list_technician_pending_reviews() to authenticated;
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

  -- 2. GATE -- 11:00 IST, same as the rehearsal.
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

  -- 4. LIVE-DEFINITION PRE-CHECK -- see header comment: the only definition consistent with the
  -- rehearsal and this migration's own design is "does not exist yet".
  select pg_get_functiondef(p.oid) into v_pre_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_technician_pending_reviews';

  if v_pre_def is not null then
    raise exception 'APPLY_REFUSED: public.list_technician_pending_reviews() already exists live before this migration ran (expected: does not exist yet) -- live definition: %',
      v_pre_def;
  end if;

  -- 5. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon, as
  -- regprocedure signatures (schema-qualified, argument types included, so it is unambiguous). This is
  -- a baseline, not an enforcement point: whatever is already leaky stays the operator's separate problem,
  -- not a reason to block this apply.
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

  -- 8. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'technician_pending_reviews', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9a. the new object exists
  select pg_get_functiondef(p.oid) into v_post_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_technician_pending_reviews';

  if v_post_def is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.list_technician_pending_reviews() does not exist after the migration ran';
  end if;

  -- 9b. DIFF-BASED leak check -- same PUBLIC/anon-executable function list, recomputed after the
  -- migration. Only entries that are NEW (present after, absent before) fail this check; a pre-existing,
  -- unrelated leaky function is reported in neither direction and never blocks this apply.
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

  -- 9c. the new function specifically is not executable by anon/PUBLIC -- absolute requirement,
  -- independent of 9b. has_function_privilege() already reflects any grant made to the PUBLIC
  -- pseudo-role (every role implicitly carries PUBLIC's grants), so checking 'anon' alone covers both.
  select has_function_privilege('anon', 'public.list_technician_pending_reviews()', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.list_technician_pending_reviews() is executable by anon/PUBLIC';
  end if;

  -- 9d. the real organisation's fingerprint is unchanged. This migration touches no table ROWS at all --
  -- only a function definition and its grants -- so this must be byte-identical to the value taken in
  -- step 0.
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row. Reaching this INSERT is only possible on
  -- a fully clean run; any earlier RAISE EXCEPTION rolls this INSERT back along with everything else in
  -- this DO block, leaving the step-1 temp table empty.
  insert into pg_temp.technician_pending_reviews_apply_status (
    migration_version, version_registered, function_exists, function_executable_by_anon,
    newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, org_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, (v_post_def is not null), v_anon_exec,
    v_newly_leaked, v_org_fingerprint_before, v_org_fingerprint_after,
    (v_org_fingerprint_after = v_org_fingerprint_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.technician_pending_reviews_apply_status;
