-- Rehearsal wrapper for 20261112100000_technician_pending_reviews.sql +
-- supabase/tests/technician_pending_reviews.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard rule for
-- this change: no DB access of any kind). The owner runs this by hand, after 18:00 IST, once satisfied the
-- sha256-pinned text embedded below for BOTH files is byte-for-byte what they reviewed.
--
-- What this guards against (2026-10-13 incident -- see supabase/tests/staff_security_fixes.test.sql and this
-- project's "migration + test concat accident" note): a test file that does NOT end in a guaranteed `raise
-- exception` was once concatenated in front of an unapproved migration, and the whole thing committed live, because
-- nothing forced a rollback. This wrapper -- and the test text it carries -- both end in
-- `raise exception E'RESULTS:%'`, never a plain `raise notice`, specifically because Postgres rolls back the WHOLE
-- transaction when a DO block raises, in every case, independent of whether whoever runs it remembered to wrap it
-- in its own BEGIN ... ROLLBACK. A single unconditional raise at the very end of this block is what makes every
-- exit path -- gate refusal, hash mismatch, or a full run -- equally safe to run by accident.
--
-- Five guarantees, in order:
--   1. LOCK  -- set_config('lock_timeout', '5s', true) for this transaction only: a blocked DDL/DML wait
--      (CREATE OR REPLACE FUNCTION, REVOKE/GRANT, or a locked row in the real tables this reads) aborts in 5s
--      with a normal error instead of hanging the session indefinitely.
--   2. GATE   -- refuses to run before 18:00 IST (this project's standing convention for risky rehearsal scripts).
--   3. PIN    -- sha256(embedded migration text) and sha256(embedded test text) must each equal the hash recorded
--      below; a silent edit of EITHER file after review refuses the whole rehearsal, nothing executed.
--   4. RUN    -- applies the pinned migration text verbatim (create-or-replace function + revoke/grant -- additive,
--      no table/RLS change), then executes the pinned test text verbatim as its own nested DO block and captures
--      its RESULTS line. Both run inside this same transaction, which this wrapper's own final line ALWAYS ends
--      with an unconditional RAISE EXCEPTION -- so this rehearsal can never itself apply the migration for real;
--      it only proves the migration and the test behave correctly together before the owner applies the real
--      migration file separately through the normal path.
--   5. PROVE  -- a fingerprint (digest) of every REAL, non-__TEST_ row across service_visits / service_tickets /
--      customers / ratings is taken before step 4 and again immediately after the test's RESULTS exception is
--      caught, and the two are compared and appended to the final result, proving step 4 touched only the
--      __TEST_ rows the embedded test created (and which its own closing RAISE already rolled back to this
--      savepoint) -- never a real customer or visit.
--
-- v_embedded_migration / v_embedded_test are each declared with the dollar-quoted text starting immediately after
-- the opening `$...$` tag (no blank line) and ending immediately before the closing tag -- so each string is
-- byte-for-byte identical to its source file (confirmed locally via sha256sum before this file was written) and
-- not off by a stray newline the pin would catch anyway.
do $rehearsal$
declare
  v_ist_hour            int;
  v_expected_migration_hash text := '24802c1c66ac4889e10b907d5c1b38e0af15c943d686a13c09080d98a62df818';
  v_expected_test_hash      text := 'cda672a547b1e0cd4f85a95cd78b9648dbf7f6162c1ebd21780db64fa7a6b128';
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before           text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_migration   text := $migration$-- Technician "Pending reviews" list (2026-11-12).
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
--   * Only visits completed in the last 60 days -- `sv.timer_end` compared against IST (Asia/Kolkata)
--     midnight 60 days before today's IST date, so the cutoff is a calendar-day boundary in the
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
    and sv.timer_end >= (((now() at time zone 'Asia/Kolkata')::date - 60) at time zone 'Asia/Kolkata')
    and not c.is_test
    and not exists (
      select 1 from public.ratings r where r.visit_id = sv.id
    )
  order by sv.timer_end desc
$$;

revoke all on function public.list_technician_pending_reviews() from public, anon, authenticated;
grant execute on function public.list_technician_pending_reviews() to authenticated;
$migration$;
  v_embedded_test text := $testbody$-- Rolled-back test for 20261112100000_technician_pending_reviews.sql (public.list_technician_pending_reviews()).
-- The runner concatenates that migration file in front of this block in ONE transaction; the block ends in
-- RAISE EXCEPTION, so nothing is committed regardless of pass/fail. Throwaway __TEST_ organisation and users only.
do $t$
declare
  res text := '';
  v_org uuid;
  v_a_profile uuid := gen_random_uuid();
  v_b_profile uuid := gen_random_uuid();
  v_a_tech uuid;
  v_b_tech uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid; v_c6 uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid; v_t6 uuid; v_t7 uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid; v_v4 uuid; v_v5 uuid; v_v6 uuid; v_v7 uuid;
  v_rows_a int; v_rows_b int;
  v_a_sees_c1 boolean; v_a_sees_c2 boolean; v_a_sees_c3 boolean; v_a_sees_inprogress boolean;
  v_a_sees_c4 boolean; v_a_sees_c5 boolean; v_a_sees_c6 boolean;
  v_b_sees_c1 boolean; v_b_sees_c3 boolean;
begin
  insert into organizations(name) values ('__TEST_pending_reviews_org') returning id into v_org;
  insert into auth.users(id, email) select x, '__test_' || x || '@example.invalid' from unnest(array[v_a_profile, v_b_profile]) x;
  insert into profiles(id, org_id, full_name, role) values
    (v_a_profile, v_org, '__TEST_tech_a', 'technician'),
    (v_b_profile, v_org, '__TEST_tech_b', 'technician');
  insert into technicians(org_id, profile_id) values (v_org, v_a_profile) returning id into v_a_tech;
  insert into technicians(org_id, profile_id) values (v_org, v_b_profile) returning id into v_b_tech;

  -- c1: A's visit, completed, NOT yet rated -> must appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c1', '9000000001') returning id into v_c1;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c1, 'completed') returning id into v_t1;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t1, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t1, v_a_tech, now() - interval '2 hours', now() - interval '1 hour') returning id into v_v1;

  -- c2: A's visit, completed, ALREADY rated -> must NOT appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c2', '9000000002') returning id into v_c2;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c2, 'completed') returning id into v_t2;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t2, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t2, v_a_tech, now() - interval '2 hours', now() - interval '1 hour') returning id into v_v2;
  insert into ratings(org_id, visit_id, stars) values (v_org, v_v2, 5);

  -- c3: B's visit, completed, NOT yet rated -> must appear for B, and must NEVER appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c3', '9000000003') returning id into v_c3;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c3, 'completed') returning id into v_t3;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t3, v_b_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t3, v_b_tech, now() - interval '2 hours', now() - interval '1 hour') returning id into v_v3;

  -- A's visit still IN PROGRESS (timer_end null) -> must NOT appear for A (not "completed" yet)
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c1, 'in_progress') returning id into v_t4;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t4, v_a_tech, 'in_progress');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t4, v_a_tech, now() - interval '10 minutes', null) returning id into v_v4;

  -- c4: A's visit, completed, NOT yet rated, but a TEST customer -> must NOT appear for A
  insert into customers(org_id, name, mobile, is_test) values (v_org, '__TEST_customer_c4', '9000000004', true) returning id into v_c4;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c4, 'completed') returning id into v_t5;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t5, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t5, v_a_tech, now() - interval '2 hours', now() - interval '1 hour') returning id into v_v5;

  -- c5: A's visit, completed 61 days ago, NOT yet rated -> too old, must NOT appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c5', '9000000005') returning id into v_c5;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c5, 'completed') returning id into v_t6;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t6, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t6, v_a_tech, now() - interval '61 days' - interval '1 hour', now() - interval '61 days') returning id into v_v6;

  -- c6: A's visit, completed 59 days ago, NOT yet rated -> within the 60-day window, must appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c6', '9000000006') returning id into v_c6;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c6, 'completed') returning id into v_t7;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t7, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_t7, v_a_tech, now() - interval '59 days' - interval '1 hour', now() - interval '59 days') returning id into v_v7;

  -- ===== POSITIVE: technician A sees exactly his own unreviewed, non-test, <=60-day-old visits (c1, c6) =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_a_profile, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into v_rows_a from public.list_technician_pending_reviews();
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c1) into v_a_sees_c1;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c2) into v_a_sees_c2;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c3) into v_a_sees_c3;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.visit_id = v_v4) into v_a_sees_inprogress;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c4) into v_a_sees_c4;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c5) into v_a_sees_c5;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c6) into v_a_sees_c6;

  res := res || E'\n' || case when v_rows_a = 2 then 'ok   P1 technician A sees exactly 2 pending-review rows (c1, c6)' else 'FAIL P1 rows=' || v_rows_a end;
  res := res || E'\n' || case when v_a_sees_c1 then 'ok   P2 technician A sees his own unreviewed customer c1' else 'FAIL P2' end;
  res := res || E'\n' || case when not v_a_sees_c2 then 'ok   P3 technician A does NOT see c2 (already rated)' else 'FAIL P3' end;
  res := res || E'\n' || case when not v_a_sees_c3 then 'ok   P4 technician A does NOT see c3 (another technician''s customer)' else 'FAIL P4' end;
  res := res || E'\n' || case when not v_a_sees_inprogress then 'ok   P5 technician A does NOT see a visit still in progress (timer_end null)' else 'FAIL P5' end;
  res := res || E'\n' || case when not v_a_sees_c4 then 'ok   P6 technician A does NOT see c4 (flagged test customer)' else 'FAIL P6 test customer leaked' end;
  res := res || E'\n' || case when not v_a_sees_c5 then 'ok   P7 technician A does NOT see c5 (visit completed 61 days ago, outside the 60-day window)' else 'FAIL P7 stale visit leaked' end;
  res := res || E'\n' || case when v_a_sees_c6 then 'ok   P8 technician A sees c6 (visit completed 59 days ago, inside the 60-day window)' else 'FAIL P8 within-window visit missing' end;

  execute 'reset role';

  -- ===== NEGATIVE: technician B can never see technician A's customer (c1), only his own (c3) =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_b_profile, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into v_rows_b from public.list_technician_pending_reviews();
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c1) into v_b_sees_c1;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c3) into v_b_sees_c3;

  res := res || E'\n' || case when v_rows_b = 1 then 'ok   N1 technician B sees exactly 1 pending-review row (his own)' else 'FAIL N1 rows=' || v_rows_b end;
  res := res || E'\n' || case when not v_b_sees_c1 then 'ok   N2 technician B does NOT see technician A''s customer c1 (strict ownership)' else 'FAIL N2 cross-technician leak' end;
  res := res || E'\n' || case when v_b_sees_c3 then 'ok   N3 technician B sees his own unreviewed customer c3' else 'FAIL N3' end;

  execute 'reset role';

  -- ===== A non-technician caller (e.g. a bare authenticated row with no technicians row) gets zero rows =====
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_rows_a from public.list_technician_pending_reviews();
  res := res || E'\n' || case when v_rows_a = 0 then 'ok   G1 a caller with no technicians row gets zero rows (current_technician_id() = null)' else 'FAIL G1 rows=' || v_rows_a end;
  execute 'reset role';

  raise exception E'RESULTS:%', res;
end
$t$;
$testbody$;
begin
  -- 1. LOCK: scoped to this transaction only (the `true` arg to set_config) -- never leaks to the
  -- connection/session beyond this rehearsal.
  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  -- 2. GATE
  if v_ist_hour < 18 then
    res := res || E'\nGATE-REFUSED this rehearsal only runs after 18:00 IST (current IST hour=' || v_ist_hour || E'); nothing executed, nothing read.';
  else
    -- 3. PIN -- both embedded files must match their recorded hash before anything runs.
    v_actual_migration_hash := encode(sha256(convert_to(v_embedded_migration, 'UTF8')), 'hex');
    v_actual_test_hash := encode(sha256(convert_to(v_embedded_test, 'UTF8')), 'hex');

    if v_actual_migration_hash is distinct from v_expected_migration_hash then
      res := res || E'\nGATE-REFUSED embedded MIGRATION text does not match its pinned sha256 (expected ' || v_expected_migration_hash
                  || E', got ' || v_actual_migration_hash || E'); nothing executed, nothing read.';
    elsif v_actual_test_hash is distinct from v_expected_test_hash then
      res := res || E'\nGATE-REFUSED embedded TEST text does not match its pinned sha256 (expected ' || v_expected_test_hash
                  || E', got ' || v_actual_test_hash || E'); nothing executed, nothing read.';
    else
      res := res || E'\nok   GATE passed: IST hour=' || v_ist_hour || E', both embedded-text sha256 hashes verified';

      -- Real-organisation fingerprint BEFORE: every real (non __TEST_) row across the tables this feature reads,
      -- reduced to one digest so "unchanged" is a single comparison. Scoped to service_visits/service_tickets/
      -- customers/ratings -- the exact set public.list_technician_pending_reviews() (and this test) touches.
      select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_before
      from (
        select sv.id::text || ':' || coalesce(r.id::text, '-') as x
        from public.service_visits sv
        join public.service_tickets t on t.id = sv.ticket_id
        join public.customers c on c.id = t.customer_id
        left join public.ratings r on r.visit_id = sv.id
        where c.name not like '\_\_TEST\_%' escape '\'
      ) real_rows;
      res := res || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before;

      -- 4. RUN -- apply the pinned migration verbatim (additive: create-or-replace function + revoke/grant).
      execute v_embedded_migration;
      res := res || E'\nok   migration applied inside this still-open transaction';

      -- Then run the pinned test text verbatim. It is itself a complete `do $t$ ... end $t$;` statement that
      -- always ends in `raise exception E'RESULTS:%'` (see the PIN guarantee above), so EXECUTE always raises
      -- here -- caught below, which also means every __TEST_ row the embedded test created is rolled back to
      -- this point before the AFTER fingerprint is taken.
      begin
        execute v_embedded_test;
        v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
      exception when others then
        v_inner_result := sqlerrm;
      end;
      res := res || E'\n--- embedded test output ---\n' || coalesce(v_inner_result, '(no result captured)') || E'\n--- end embedded test output ---';

      -- 5. PROVE -- fingerprint again now that the exception above has rolled the test's __TEST_ rows back to
      -- the savepoint, then compare and append the result (never skipped, whichever way the comparison lands).
      select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_after
      from (
        select sv.id::text || ':' || coalesce(r.id::text, '-') as x
        from public.service_visits sv
        join public.service_tickets t on t.id = sv.ticket_id
        join public.customers c on c.id = t.customer_id
        left join public.ratings r on r.visit_id = sv.id
        where c.name not like '\_\_TEST\_%' escape '\'
      ) real_rows;
      res := res || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after;
      res := res || E'\n' || case when v_fp_after = v_fp_before
                              then 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data'
                              else 'FAIL real-organisation fingerprint CHANGED -- investigate before trusting anything above' end;
    end if;
  end if;

  -- Unconditional final line, every path (gate refusal, hash mismatch, or a full run) lands here exactly once,
  -- with the fingerprint comparison already appended above whenever step 4 actually ran.
  raise exception E'RESULTS:%', res;
end
$rehearsal$;
