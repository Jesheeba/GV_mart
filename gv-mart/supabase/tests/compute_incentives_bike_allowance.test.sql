-- Rolled-back check for 20261024100500_compute_incentives_bike_allowance.sql,
-- rebuilt against the real live body (after 20261016150000_review_
-- incentives_switch, itself after 20261016120000_installation_incentive_
-- credits and 20261016110000_test_customer_flag). Uses its own throwaway
-- organisation so this test's incentive_rules/credit rows never interact
-- with another org's data. Run through the Management API (database/query);
-- it always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid; v_t3 uuid; v_t3p uuid; v_t4 uuid; v_t4p uuid;
  v_amount numeric; v_n int; v_base numeric; v_reason text;
  v_before_count int; v_after_count int;
  v_rule_id uuid;
  v_credit_row incentives_earned;
begin
  insert into organizations (name) values ('__TEST_monthly_expenses_bike_allowance') returning id into v_org;
  insert into settings (org_id) values (v_org);
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'bike-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  v_t1 := gen_random_uuid(); v_t2 := gen_random_uuid(); v_t3 := gen_random_uuid(); v_t4 := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 't1@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 't2@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t3, 'authenticated', 'authenticated', 't3@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t4, 'authenticated', 'authenticated', 't4@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t3, v_org, '__TEST_ tech3', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t4, v_org, '__TEST_ tech4', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1p;
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2p;
  insert into technicians (org_id, profile_id) values (v_org, v_t3) returning id into v_t3p;
  insert into technicians (org_id, profile_id) values (v_org, v_t4) returning id into v_t4p;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Technician on their own bike all month receives the full base amount
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t1p, 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('own all month (expect base=%s): %s', v_base, v_amount);

  -- Technician on a company bike all month receives nothing
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t2p, 'company', 0, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_t2p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('company all month, rows created (expect 0): %s', v_n);

  -- Mid-month switch (own 1-11, company 12-30 in a 30-day April)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3p, 'own', 2, '2026-04-01', '2026-04-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3p, 'company', 0, '2026-04-12', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('mid-month switch (expect round(%s*11/30,2)=%s): %s', v_base, round(v_base * 11 / 30, 2), v_amount);

  -- An extra with a reason adds on top, and the reason is retrievable
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_t3, '2026-04-01', 'bike_allowance', 'top_up', 150, 'new tyres this month, approved by master');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('with extra (expect prorated+150=%s): %s', round(v_base * 11 / 30, 2) + 150, v_amount);
  select reason into v_reason from monthly_adjustments where profile_id = v_t3 and adjustment_target = 'bike_allowance' limit 1;
  res := res || E'\n' || format('extra reason retrievable: %s', v_reason);

  -- Every existing component of the incentive total is unchanged: a
  -- technician with NO vehicle row produces no bike-allowance row, and
  -- re-running compute_incentives for them is a no-op (idempotent).
  select count(*) into v_before_count from incentives_earned where technician_id = v_t4p and period = '2026-04-01';
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_after_count from incentives_earned where technician_id = v_t4p and period = '2026-04-01';
  res := res || E'\n' || format('no-vehicle technician row count before=%s after=%s (expect equal)', v_before_count, v_after_count);
  select count(*) into v_n from incentives_earned where technician_id = v_t4p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('no-vehicle technician bike-allowance rows (expect 0): %s', v_n);

  -- The bike-allowance row and a credit_source row coexist for the same
  -- technician/period without violating the widened 4-way constraint
  -- (the credit row is inserted directly here, bypassing the real ticket/
  -- approval flow, which is out of scope for this test). The live
  -- installation-ticket-credits block recomputes its figure from
  -- installation_incentive_credits on EVERY run regardless of what this
  -- feature does — with no real backing credit row, the verbatim-preserved
  -- block correctly overwrites the manually-seeded 500 down to 0. That is
  -- the real live behaviour (by design, so a late void is reflected) and
  -- confirms the bike-allowance block did not change it: it is testing the
  -- live block exactly as it already worked before this feature existed.
  insert into incentives_earned (org_id, technician_id, credit_source, amount, period)
    values (v_org, v_t1p, 'installation_ticket', 500, '2026-04-01');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_t1p and period = '2026-04-01';
  res := res || E'\n' || format('bike-allowance + credit_source coexist for same technician/period (expect 2 rows): %s', v_n);
  select * into v_credit_row from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and credit_source = 'installation_ticket';
  res := res || E'\n' || format('credit_source row recomputed from the (empty) real credits table, unrelated to this feature (expect 0, not the seeded 500): %s', v_credit_row.amount);

  -- The review_incentives_enabled switch (default OFF) does not affect the
  -- bike-allowance block either way.
  update settings set review_incentives_enabled = true where org_id = v_org;
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('bike allowance unaffected by review switch ON (still expect base=%s): %s', v_base, v_amount);

  -- Malformed rows: the widened 4-way check still rejects two sources set,
  -- and still rejects zero sources set — exactly what the narrower 3-way
  -- check (installation_incentive_credits) already rejected.
  insert into incentive_rules (org_id, type, threshold, amount) values (v_org, 'service_income', 1000, 100) returning id into v_rule_id;
  begin
    insert into incentives_earned (org_id, technician_id, rule_id, installation_rate_id, amount, period)
      values (v_org, v_t2p, v_rule_id, gen_random_uuid(), 10, '2026-04-01');
    res := res || E'\n' || 'two sources set: SUCCEEDED (bad, unless no incentive_rules row exists to reference)';
  exception when others then
    res := res || E'\n' || 'two sources set: rejected ('||sqlerrm||')';
  end;
  begin
    insert into incentives_earned (org_id, technician_id, amount, period) values (v_org, v_t2p, 10, '2026-04-01');
    res := res || E'\n' || 'zero sources set: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'zero sources set: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
