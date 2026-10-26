-- Unit 8 — end to end. One month, one organisation, seven technicians:
-- own bike all month, company bike all month, mid-month switch, an excluded
-- month, a top-up, a claim verified lower than submitted, and no expenses at
-- all. Rolled-back check — run through the Management API (database/query);
-- it always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_own uuid; v_own_p uuid;
  v_company uuid; v_company_p uuid;
  v_switch uuid; v_switch_p uuid;
  v_excluded uuid; v_excluded_p uuid;
  v_topup uuid; v_topup_p uuid;
  v_lowball uuid; v_lowball_p uuid;
  v_none uuid; v_none_p uuid;
  v_row salaries; v_none_before salaries; v_none_after salaries;
  v_claim public.expense_claims;
  v_base numeric;
  v_org_total numeric; v_manual_sum numeric;
  ids uuid[];
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  select array_agg(id) into ids from (select id from technicians where org_id = v_org limit 7) s;
  if array_length(ids, 1) < 7 then
    raise exception 'RESULTSUnit 8 skipped: this database has fewer than 7 technicians seeded (found %)', array_length(ids, 1);
  end if;
  v_own := ids[1]; v_company := ids[2]; v_switch := ids[3]; v_excluded := ids[4];
  v_topup := ids[5]; v_lowball := ids[6]; v_none := ids[7];
  select profile_id into v_own_p from technicians where id = v_own;
  select profile_id into v_company_p from technicians where id = v_company;
  select profile_id into v_switch_p from technicians where id = v_switch;
  select profile_id into v_excluded_p from technicians where id = v_excluded;
  select profile_id into v_topup_p from technicians where id = v_topup;
  select profile_id into v_lowball_p from technicians where id = v_lowball;
  select profile_id into v_none_p from technicians where id = v_none;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- The no-expenses technician: snapshot salary before touching anything.
  select * into v_none_before from compute_salary(v_org, v_none, '2026-07-01');

  -- Own bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_own, 'own', 3, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_own, '2026-07-10', 40);

  -- Company bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_company, 'company', 0, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_company, '2026-07-10', 40);

  -- Mid-month switch (own 1-15, company 16-31 — a 31-day month)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'own', 2, '2026-07-01', '2026-07-15');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'company', 0, '2026-07-16', '2026-07-31');

  -- Excluded month for the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_excluded_p, 300, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_excluded_p, '2026-07-01', 'recharge', 'exclude', null, 'left mid-month, withheld for July');

  -- Top-up on the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_topup_p, 250, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_topup_p, '2026-07-01', 'recharge', 'top_up', 100, 'extra SIM for the second line this month');

  -- A maintenance claim verified lower than submitted
  perform set_config('request.jwt.claims', json_build_object('sub', v_lowball_p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 1000, v_lowball::text || '/bill.jpg', '2026-07-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform verify_expense_claim(v_claim.id, 650, 'bill included unrelated personal items');

  perform compute_incentives(v_org, '2026-07-01');

  -- Petrol reference figures are informational (km*rate, Fix 5): neither
  -- technician submitted a petrol claim this month, so petrol_amount (what
  -- is actually paid) is correctly 0 for both regardless of their reference
  -- figure — owner revision: the verified claim pays, not km*rate.
  select * into v_row from compute_salary(v_org, v_own, '2026-07-01');
  res := res || E'\n' || format(
    'own-all-month: petrol_reference=%s (expect 120) petrol_amount=%s (expect 0, no claim submitted) bike_allowance_amount=%s (expect base=%s)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount, v_base
  );

  select * into v_row from compute_salary(v_org, v_company, '2026-07-01');
  res := res || E'\n' || format(
    'company-all-month: petrol_reference=%s (expect 0, rate is 0) petrol_amount=%s (expect 0) bike_allowance_amount=%s (expect 0)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount
  );

  select * into v_row from compute_salary(v_org, v_switch, '2026-07-01');
  res := res || E'\n' || format('mid-month-switch: bike_allowance_amount=%s (expect round(%s*15/31,2)=%s)', v_row.bike_allowance_amount, v_base, round(v_base * 15 / 31, 2));

  select * into v_row from compute_salary(v_org, v_excluded, '2026-07-01');
  res := res || E'\n' || format('excluded-month: recharge_amount=%s (expect 0, not 300)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_topup, '2026-07-01');
  res := res || E'\n' || format('top-up: recharge_amount=%s (expect 250+100=350)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_lowball, '2026-07-01');
  res := res || E'\n' || format('verified-lower: maintenance_amount=%s (expect 650, not 1000)', v_row.maintenance_amount);

  -- The technician with no expenses at all is entirely unaffected
  select * into v_none_after from compute_salary(v_org, v_none, '2026-07-01');
  res := res || E'\n' || format(
    'no-expenses technician unaffected: recharge=%s petrol=%s maintenance=%s bike_extra=%s, net unchanged=%s',
    v_none_after.recharge_amount, v_none_after.petrol_amount, v_none_after.maintenance_amount, v_none_after.bike_allowance_extra,
    v_none_before.net = v_none_after.net
  );

  -- Monthly report invariant: org total (these 7) equals the sum of the
  -- per-technician figures.
  select sum(recharge_amount + petrol_amount + maintenance_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-07-01' and technician_id = any(ids);
  select sum(s.recharge_amount + s.petrol_amount + s.maintenance_amount) into v_manual_sum
    from (select recharge_amount, petrol_amount, maintenance_amount from salaries where technician_id = any(ids) and period = '2026-07-01') s;
  res := res || E'\n' || format('org total reconciles with per-technician sum: %s', v_org_total = v_manual_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
