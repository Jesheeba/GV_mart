-- Rehearsal wrapper for supabase/tests/technician_pending_reviews.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard rule for
-- this change: no DB access of any kind). The owner runs this by hand, after 18:00 IST, once satisfied the
-- sha256-pinned text embedded below is byte-for-byte the test file they reviewed.
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
-- Four guarantees, in order:
--   1. GATE   -- refuses to run before 18:00 IST (this project's standing convention for risky rehearsal scripts).
--   2. PIN    -- sha256(embedded test text) must equal the hash recorded below; a silent edit after review refuses.
--   3. RUN    -- executes the pinned text verbatim, as its own nested DO block, and captures its RESULTS line.
--   4. PROVE  -- a fingerprint (digest) of every REAL, non-__TEST_ row across service_visits / service_tickets /
--      customers / ratings is taken before and after, and asserted unchanged, proving the test above touched only
--      the __TEST_ rows it created and rolled back -- never a real customer or visit.
--
-- v_embedded is intentionally declared with the dollar-quoted text starting immediately after the `$embed$` tag (no
-- blank line) and ending immediately before the closing `$embed$` tag -- so the string is byte-for-byte identical
-- to supabase/tests/technician_pending_reviews.test.sql (confirmed locally via sha256sum before this file was
-- written) and not off by a stray newline the pin would catch anyway.
do $rehearsal$
declare
  v_ist_hour      int;
  v_expected_hash text := '15100464a760401e3824ad5d3df1e984285960d241b992428cf35dc053e0f0e8';
  v_actual_hash   text;
  v_fp_before     text;
  v_fp_after      text;
  v_inner_result  text;
  res             text := '';
  v_embedded      text := $embed$-- Rolled-back test for 20261112100000_technician_pending_reviews.sql (public.list_technician_pending_reviews()).
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
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid; v_v4 uuid;
  v_rows_a int; v_rows_b int;
  v_a_sees_c1 boolean; v_a_sees_c2 boolean; v_a_sees_c3 boolean; v_a_sees_inprogress boolean;
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

  -- ===== POSITIVE: technician A sees exactly his own unreviewed completed visit (c1), nothing else =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_a_profile, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into v_rows_a from public.list_technician_pending_reviews();
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c1) into v_a_sees_c1;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c2) into v_a_sees_c2;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c3) into v_a_sees_c3;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.visit_id = v_v4) into v_a_sees_inprogress;

  res := res || E'\n' || case when v_rows_a = 1 then 'ok   P1 technician A sees exactly 1 pending-review row' else 'FAIL P1 rows=' || v_rows_a end;
  res := res || E'\n' || case when v_a_sees_c1 then 'ok   P2 technician A sees his own unreviewed customer c1' else 'FAIL P2' end;
  res := res || E'\n' || case when not v_a_sees_c2 then 'ok   P3 technician A does NOT see c2 (already rated)' else 'FAIL P3' end;
  res := res || E'\n' || case when not v_a_sees_c3 then 'ok   P4 technician A does NOT see c3 (another technician''s customer)' else 'FAIL P4' end;
  res := res || E'\n' || case when not v_a_sees_inprogress then 'ok   P5 technician A does NOT see a visit still in progress (timer_end null)' else 'FAIL P5' end;

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
$embed$;
begin
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  if v_ist_hour < 18 then
    res := res || E'\nGATE-REFUSED this rehearsal only runs after 18:00 IST (current IST hour=' || v_ist_hour || E'); nothing executed, nothing read.';
  else
    v_actual_hash := encode(sha256(convert_to(v_embedded, 'UTF8')), 'hex');
    if v_actual_hash is distinct from v_expected_hash then
      res := res || E'\nGATE-REFUSED embedded test text does not match its pinned sha256 (expected ' || v_expected_hash
                  || E', got ' || v_actual_hash || E'); nothing executed, nothing read.';
    else
      res := res || E'\nok   GATE passed: IST hour=' || v_ist_hour || E', embedded-text sha256 verified';

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

      -- Run the pinned test text verbatim. It is itself a complete `do $t$ ... end $t$;` statement that always
      -- ends in `raise exception E'RESULTS:%'` (see the PIN guarantee above), so EXECUTE always raises here --
      -- caught below as a savepoint-scoped exception, which also means every __TEST_ row the embedded test
      -- created is rolled back to this point before the AFTER fingerprint is taken.
      begin
        execute v_embedded;
        v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
      exception when others then
        v_inner_result := sqlerrm;
      end;
      res := res || E'\n--- embedded test output ---\n' || coalesce(v_inner_result, '(no result captured)') || E'\n--- end embedded test output ---';

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

  -- Unconditional final line, every path (gate refusal, hash mismatch, or a full run) lands here exactly once.
  raise exception E'RESULTS:%', res;
end
$rehearsal$;
