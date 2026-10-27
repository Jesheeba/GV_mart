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
