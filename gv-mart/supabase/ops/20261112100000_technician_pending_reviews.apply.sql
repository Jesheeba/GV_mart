-- GO APPLY script for migration 20261112100000_technician_pending_reviews.sql
-- (public.list_technician_pending_reviews()), commit 81621b7a5512deb533dab98db961e631ae53ec40 on
-- feat/technician-pending-reviews.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 18:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 55b33aaf1d276984e3873b46a8e413393b87dbe3c094ddef67483d07a8c408a3).
--
-- Unlike the rehearsal wrapper (supabase/ops/technician_pending_reviews.rehearsal.sql), THIS SCRIPT IS
-- MEANT TO COMMIT. The DO block is wrapped in an explicit BEGIN; ... COMMIT; (not an implicit
-- autocommit statement): any RAISE EXCEPTION inside the DO block -- gate refusal, hash mismatch,
-- already-registered version, live-definition drift, or a failed post-apply check -- rolls back the
-- WHOLE transaction (the migration itself and the schema_migrations row together), and the script falls
-- through to COMMIT only when every step inside has passed cleanly. There is no embedded test and no
-- forced closing RAISE; the exact Postgres error from whichever step failed is what the operator sees in
-- psql, and nothing is persisted.
--
-- Order of operations:
--   0. ORG CHECK   -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint. Refuses immediately if this looks like the wrong database.
--   1. LOCK        -- lock_timeout = 5s for this transaction only.
--   2. GATE        -- refuses before 18:00 IST (same convention, and the same hour, as the rehearsal --
--      NOT 11:00).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261112100000, refuse immediately. Re-running this script after a successful apply is always a
--      safe no-op refusal, never a double-apply.
--   4. LIVE-DEFINITION PRE-CHECK -- this migration only ever CREATEs public.list_technician_pending_reviews()
--      for the first time; it does not replace an existing different body. The rehearsal never pinned a
--      "live before" definition for it (the rehearsal's own real-row fingerprint only covers table DATA,
--      not function DEFINITIONS), so this script pins the only definition consistent with that rehearsal
--      run and with this migration's own design: NULL, i.e. the function must not already exist live.
--      If it already exists -- under any definition -- that is a drift from what both the migration and
--      the rehearsal assumed, so this refuses rather than silently overwriting a live function nobody
--      reviewed.
--   5. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash
--      above (same CR-tolerance fix as the rehearsal wrapper, commit 81621b7a).
--   6. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   7. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself, so the two can never go out of sync.
--   8. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      8a. the new function exists;
--      8b. zero rows of "functions in public executable by PUBLIC/anon" (schema-wide invariant);
--      8c. the new function specifically is not executable by anon/PUBLIC (has_function_privilege also
--          reflects any grant made to the PUBLIC pseudo-role, since every role implicitly carries
--          PUBLIC's grants, so this one check covers both anon and PUBLIC for this function);
--      8d. the real organisation's fingerprint is unchanged (this migration touches no table ROWS at
--          all -- only a function definition and its grants -- so this must be byte-identical to the
--          value taken in step 0).
--
-- No test file is embedded and there is no rollback script invoked here: the rollback for this migration
-- already exists separately at supabase/rollbacks/20261112100000_technician_pending_reviews.rollback.sql
-- and is run by hand, outside this script, only if the owner decides afterwards to undo the change.
begin;
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
  v_leaked_function_count    int;
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

  -- 2. GATE -- 18:00 IST, same as the rehearsal.
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

  -- 5. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 6. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 7. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'technician_pending_reviews', array[replace(v_embedded_migration, E'\r', '')]);

  -- 8a. the new object exists
  select pg_get_functiondef(p.oid) into v_post_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_technician_pending_reviews';

  if v_post_def is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.list_technician_pending_reviews() does not exist after the migration ran';
  end if;

  -- 8b. zero rows of "functions in public executable by PUBLIC/anon" (schema-wide invariant; grantee = 0
  -- is the special aclexplode() encoding for a grant to the PUBLIC pseudo-role).
  select count(*) into v_leaked_function_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where n.nspname = 'public'
    and a.privilege_type = 'EXECUTE'
    and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'));

  if v_leaked_function_count <> 0 then
    raise exception 'APPLY_REFUSED: post-apply check failed -- % function(s) in schema public are executable by PUBLIC/anon',
      v_leaked_function_count;
  end if;

  -- 8c. the new function specifically is not executable by anon/PUBLIC. has_function_privilege() already
  -- reflects any grant made to the PUBLIC pseudo-role (every role implicitly carries PUBLIC's grants), so
  -- checking the 'anon' role alone covers both anon and PUBLIC for this one function.
  select has_function_privilege('anon', 'public.list_technician_pending_reviews()', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.list_technician_pending_reviews() is executable by anon/PUBLIC';
  end if;

  -- 8d. the real organisation's fingerprint is unchanged. This migration touches no table ROWS at all --
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

  raise notice 'APPLY_OK: migration % applied, registered, and all post-apply checks passed', v_migration_version;
end
$apply$;
commit;
