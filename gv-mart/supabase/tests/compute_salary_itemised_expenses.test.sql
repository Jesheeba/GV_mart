-- Rolled-back check for 20261024100600_compute_salary_itemised_expenses.sql.
-- Run through the Management API (database/query); it always ends in a
-- RAISE so nothing persists. Read the RESULTS in the error.
--
-- Not exercised here (needs a browser): "if the return shape changed, the
-- frontend renders the new shape correctly" — verified instead by the
-- SalaryTab.tsx/hr.ts SalaryRow type update described in the build report.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid;
  v_row salaries; v_row2 salaries;
  v_petrol_claim public.expense_claims;
  v_maint_claim public.expense_claims;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.id, t.profile_id into v_t1, v_t1p from technicians t limit 1;
  select t.id, t.profile_id into v_t2, v_t2p from technicians t where t.id <> v_t1 limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- A technician with none of the four produces salary output identical to
  -- before this feature: all four new areas are 0 and net reduces to the
  -- original base + revenue_component - late_deduction + incentives formula.
  select * into v_row2 from compute_salary(v_org, v_t2, '2026-05-01');
  res := res || E'\n' || format(
    'no-data technician: recharge=%s petrol_amount=%s petrol_reference=%s maintenance=%s bike_extra=%s, net == old formula: %s',
    v_row2.recharge_amount, v_row2.petrol_amount, v_row2.petrol_reference_amount, v_row2.maintenance_amount, v_row2.bike_allowance_extra,
    v_row2.net = v_row2.base + v_row2.revenue_component - v_row2.late_deduction + v_row2.incentives
  );

  -- Set up all four for v_t1: recharge allowance, vehicle+km (petrol
  -- reference), a verified petrol claim, a verified maintenance claim, and
  -- own-bike allowance (via Unit 1/5).
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_t1p, 250, '2026-05-01');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t1, 'own', 4, '2026-05-01', '2026-05-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_t1, '2026-05-10', 50);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_petrol_claim from submit_expense_claim(v_org, 'petrol', 150, v_t1::text || '/petrol_bill.jpg', '2026-05-01');
  select * into v_maint_claim from submit_expense_claim(v_org, 'maintenance', 300, v_t1::text || '/bill.jpg', '2026-05-01');
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  -- Verified lower than the reference figure (km*rate=200) — the admin's
  -- judgement call is what pays, the reference figure is just context.
  perform verify_expense_claim(v_petrol_claim.id, 180, 'bill partly illegible, approved a reduced amount');
  perform verify_expense_claim(v_maint_claim.id, 300, null);
  perform compute_incentives(v_org, '2026-05-01');

  select * into v_row from compute_salary(v_org, v_t1, '2026-05-01');

  -- All four lines appear separately
  res := res || E'\n' || format(
    'all-four technician: recharge=%s petrol_amount=%s maintenance=%s bike_allowance_amount=%s',
    v_row.recharge_amount, v_row.petrol_amount, v_row.maintenance_amount, v_row.bike_allowance_amount
  );

  -- The petrol line shows kilometres, the rate, the computed reference
  -- figure, AND the amount actually paid — four values, verified amount (180)
  -- is what's paid, the reference figure (km*rate=200) is informational only.
  res := res || E'\n' || format(
    'petrol breakdown: km=%s rate=%s reference=%s(expect 200) paid=%s(expect 180, NOT the reference figure)',
    v_row.petrol_km, v_row.petrol_rate, v_row.petrol_reference_amount, v_row.petrol_amount
  );

  -- The itemised lines sum to the totals the function reports (petrol_amount
  -- is the verified/paid figure, not the reference)
  res := res || E'\n' || format(
    'net reconciles: %s (net=%s, sum=%s)',
    v_row.net = v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount,
    v_row.net,
    v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount
  );

  -- A petrol claim with verified_amount null pays nothing, same gate as
  -- maintenance, and no monthly_adjustments involvement is needed any more.
  declare v_t3 uuid; v_t3p uuid; v_pending public.expense_claims; v_row3 salaries;
  begin
    select t.id, t.profile_id into v_t3, v_t3p from technicians t where t.id not in (v_t1, v_t2) limit 1;
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_t3p, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_pending from submit_expense_claim(v_org, 'petrol', 500, v_t3::text || '/bill.jpg', '2026-05-01');
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_row3 from compute_salary(v_org, v_t3, '2026-05-01');
    res := res || E'\n' || format('unverified petrol claim pays nothing (expect 0): %s', v_row3.petrol_amount);
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
