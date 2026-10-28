-- Rolled-back test for 20261112100000_technician_pending_reviews.sql (public.list_technician_pending_reviews()).
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
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid; v_c6 uuid; v_c7 uuid; v_c8 uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid; v_t6 uuid; v_t7 uuid; v_t8 uuid; v_t9 uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid; v_v4 uuid; v_v5 uuid; v_v6 uuid; v_v7 uuid; v_v8 uuid; v_v9 uuid;
  v_rows_a int; v_rows_b int;
  v_a_sees_c1 boolean; v_a_sees_c2 boolean; v_a_sees_c3 boolean; v_a_sees_inprogress boolean;
  v_a_sees_c4 boolean; v_a_sees_c5 boolean; v_a_sees_c6 boolean; v_a_sees_c7 boolean; v_a_sees_c8 boolean;
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

  -- c7: A's visit, timer_end = 00:30 IST exactly 60 days ago (i.e. the cutoff instant plus 30 minutes) ->
  -- inside the window (>=), must appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c7', '9000000007') returning id into v_c7;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c7, 'completed') returning id into v_t8;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t8, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (
      v_org, v_t8, v_a_tech,
      ((((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp + interval '30 minutes') at time zone 'Asia/Kolkata') - interval '1 hour',
      ((((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp + interval '30 minutes') at time zone 'Asia/Kolkata')
    ) returning id into v_v8;

  -- c8: A's visit, timer_end = 23:30 IST the day before the cutoff (i.e. the cutoff instant minus 30 minutes) ->
  -- outside the window (< cutoff), must NOT appear for A
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_c8', '9000000008') returning id into v_c8;
  insert into service_tickets(org_id, customer_id, status) values (v_org, v_c8, 'completed') returning id into v_t9;
  insert into appointments(org_id, ticket_id, technician_id, status) values (v_org, v_t9, v_a_tech, 'completed');
  insert into service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (
      v_org, v_t9, v_a_tech,
      ((((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp - interval '30 minutes') at time zone 'Asia/Kolkata') - interval '1 hour',
      ((((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp - interval '30 minutes') at time zone 'Asia/Kolkata')
    ) returning id into v_v9;

  -- ===== POSITIVE: technician A sees exactly his own unreviewed, non-test, <=60-day-old visits (c1, c6, c7) =====
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
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c7) into v_a_sees_c7;
  select exists(select 1 from public.list_technician_pending_reviews() x where x.customer_id = v_c8) into v_a_sees_c8;

  res := res || E'\n' || case when v_rows_a = 3 then 'ok   P1 technician A sees exactly 3 pending-review rows (c1, c6, c7)' else 'FAIL P1 rows=' || v_rows_a end;
  res := res || E'\n' || case when v_a_sees_c1 then 'ok   P2 technician A sees his own unreviewed customer c1' else 'FAIL P2' end;
  res := res || E'\n' || case when not v_a_sees_c2 then 'ok   P3 technician A does NOT see c2 (already rated)' else 'FAIL P3' end;
  res := res || E'\n' || case when not v_a_sees_c3 then 'ok   P4 technician A does NOT see c3 (another technician''s customer)' else 'FAIL P4' end;
  res := res || E'\n' || case when not v_a_sees_inprogress then 'ok   P5 technician A does NOT see a visit still in progress (timer_end null)' else 'FAIL P5' end;
  res := res || E'\n' || case when not v_a_sees_c4 then 'ok   P6 technician A does NOT see c4 (flagged test customer)' else 'FAIL P6 test customer leaked' end;
  res := res || E'\n' || case when not v_a_sees_c5 then 'ok   P7 technician A does NOT see c5 (visit completed 61 days ago, outside the 60-day window)' else 'FAIL P7 stale visit leaked' end;
  res := res || E'\n' || case when v_a_sees_c6 then 'ok   P8 technician A sees c6 (visit completed 59 days ago, inside the 60-day window)' else 'FAIL P8 within-window visit missing' end;
  res := res || E'\n' || case when v_a_sees_c7 then 'ok   P9 technician A sees c7 (timer_end = IST midnight 60 days ago + 30 minutes, inside the window)' else 'FAIL P9 boundary-inclusive visit missing' end;
  res := res || E'\n' || case when not v_a_sees_c8 then 'ok   P10 technician A does NOT see c8 (timer_end = IST midnight 60 days ago - 30 minutes, outside the window)' else 'FAIL P10 boundary-exclusive visit leaked' end;

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
