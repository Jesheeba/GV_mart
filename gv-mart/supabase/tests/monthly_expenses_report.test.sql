-- Rolled-back check for Unit 7 (monthly report). The report itself is a
-- frontend aggregation over `salaries` (see src/services/reports.ts's
-- getMonthlyExpensesReport) — same convention as every other report tab in
-- this codebase (no SQL view/function). This test verifies the invariants
-- that aggregation depends on: unverified claims and excluded amounts never
-- reach `salaries` in the first place, and the per-technician figures sum
-- to the org total by construction (plain SUM over the same column). Run
-- through the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid;
  v_claim public.expense_claims;
  v_sum numeric; v_org_total numeric;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.id, t.profile_id into v_t1, v_t1p from technicians t limit 1;
  select t.id, t.profile_id into v_t2, v_t2p from technicians t where t.id <> v_t1 limit 1;

  -- Submitted as the technician (submit_expense_claim resolves identity
  -- from current_technician_id(), so the caller must actually be one).
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 400, v_t1::text || '/bill.jpg', '2026-06-01');
  execute 'reset role';

  -- An unverified maintenance claim never reaches salary / the report
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('unverified claim excluded from salaries.maintenance_amount (expect 0): %s', v_sum);

  -- Verify it, then re-verify at zero — Fix 4: neither petrol nor
  -- maintenance uses monthly_adjustments any more; re-verifying at zero IS
  -- how an admin withholds a previously-verified claim. The report (reading
  -- salaries) must show 0, not the earlier verified figure.
  perform verify_expense_claim(v_claim.id, 400, null);
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('verified claim reaches salary before withholding (expect 400): %s', v_sum);

  perform verify_expense_claim(v_claim.id, 0, 'disputed bill, withheld pending review');
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('withheld (re-verified at zero) shows 0 in salaries (expect 0): %s', v_sum);

  -- The organisation total equals the sum of the per-technician figures
  perform compute_salary(v_org, v_t2, '2026-06-01');
  select sum(maintenance_amount + recharge_amount + petrol_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-06-01' and technician_id in (v_t1, v_t2);
  select coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_t1 and period='2026-06-01'), 0)
       + coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_t2 and period='2026-06-01'), 0)
    into v_sum;
  res := res || E'\n' || format('org total equals sum of per-technician figures: %s (org=%s, manual_sum=%s)', v_org_total = v_sum, v_org_total, v_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
