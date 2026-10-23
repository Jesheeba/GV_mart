-- Rolled-back check for 20261024100500_compute_incentives_bike_allowance.sql.
-- Run through the Management API (database/query); it always ends in a
-- RAISE so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid; v_t3 uuid; v_t3p uuid; v_t4 uuid; v_t4p uuid;
  v_amount numeric; v_n int; v_base numeric; v_reason text;
  v_before_count int; v_after_count int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  select t.id, t.profile_id into v_t1, v_t1p from technicians t limit 1;
  select t.id into v_t2 from technicians t where t.id <> v_t1 limit 1;
  select profile_id into v_t2p from technicians where id = v_t2;
  select t.id into v_t3 from technicians t where t.id not in (v_t1, v_t2) limit 1;
  select profile_id into v_t3p from technicians where id = v_t3;
  select t.id into v_t4 from technicians t where t.id not in (v_t1, v_t2, v_t3) limit 1;
  select profile_id into v_t4p from technicians where id = v_t4;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Technician on their own bike all month receives the full base amount
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t1, 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t1 and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('own all month (expect base=%s): %s', v_base, v_amount);

  -- Technician on a company bike all month receives nothing
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t2, 'company', 0, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_t2 and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('company all month, rows created (expect 0): %s', v_n);

  -- The mid-month switch from Unit 1 (own 1-11, company 12-30 in a 30-day
  -- April) produces the pro-rated amount; assert the exact rupee figure.
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3, 'own', 2, '2026-04-01', '2026-04-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3, 'company', 0, '2026-04-12', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3 and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('mid-month switch (expect round(%s*11/30,2)=%s): %s', v_base, round(v_base * 11 / 30, 2), v_amount);

  -- An extra with a reason adds on top, and the reason is retrievable
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_t3p, '2026-04-01', 'bike_allowance', 'top_up', 150, 'new tyres this month, approved by master');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3 and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('with extra (expect prorated+150=%s): %s', round(v_base * 11 / 30, 2) + 150, v_amount);
  select reason into v_reason from monthly_adjustments where profile_id = v_t3p and adjustment_target = 'bike_allowance' limit 1;
  res := res || E'\n' || format('extra reason retrievable: %s', v_reason);

  -- Every existing component of the incentive total is unchanged: a
  -- technician with NO vehicle row produces no bike-allowance row, and
  -- re-running compute_incentives for them is a no-op (idempotent), the
  -- same way every other component already behaves.
  select count(*) into v_before_count from incentives_earned where technician_id = v_t4 and period = '2026-04-01';
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_after_count from incentives_earned where technician_id = v_t4 and period = '2026-04-01';
  res := res || E'\n' || format('no-vehicle technician row count before=%s after=%s (expect equal, both 0 bike-allowance rows)', v_before_count, v_after_count);
  select count(*) into v_n from incentives_earned where technician_id = v_t4 and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('no-vehicle technician bike-allowance rows (expect 0): %s', v_n);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
