-- Rolled-back check for 20261024100700_salary_period_locks.sql. Uses its
-- own throwaway organisation. Run through the Management API
-- (database/query); it always ends in a RAISE so nothing persists. Read
-- the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid; v_tier uuid; v_n int;
  v_salary salaries; v_lock salary_period_locks;
  v_claim public.expense_claims;
begin
  insert into organizations (name) values ('__TEST_salary_period_locks') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'spl-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  insert into technician_tiers (org_id, rank, name, monthly_salary) values (v_org, 1, '__TEST_ tier 1', 1000)
    returning id into v_tier;

  v_t1 := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 'spl-t1@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into technicians (org_id, profile_id, tier_id) values (v_org, v_t1, v_tier) returning id into v_t1p;

  -- A second technician, deliberately given no tier_id at all, to exercise
  -- the removed-fallback behaviour below.
  v_t2 := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 'spl-t2@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2 (no tier)', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2p;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- The rank-1 fallback is gone: a technician with no tier_id blocks,
  -- naming the technician and period, rather than silently substituting
  -- another tier's figure or flooring to zero.
  begin
    perform compute_salary(v_org, v_t2p, '2026-05-01');
    res := res || E'\n' || 'compute_salary for a technician with no tier assigned: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'compute_salary for a technician with no tier assigned: rejected ('||sqlerrm||')';
  end;

  -- A properly tiered technician runs cleanly end to end with the lock
  -- guard in place; base comes from the assigned tier, not a fallback.
  select * into v_salary from compute_salary(v_org, v_t1p, '2026-05-01');
  res := res || E'\n' || format('compute_salary for a properly tiered technician: base=%s net=%s', v_salary.base, v_salary.net);

  -- Lock the period
  select * into v_lock from lock_salary_period(v_org, '2026-05-01');
  res := res || E'\n' || format('lock_salary_period: locked=%s', v_lock.locked);

  -- compute_salary refuses a locked period
  begin
    perform compute_salary(v_org, v_t1p, '2026-05-01');
    res := res || E'\n' || 'compute_salary on a locked period: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'compute_salary on a locked period: rejected ('||sqlerrm||')';
  end;

  -- The table-level guard also blocks a direct UPDATE (RLS-permitted for
  -- master, which is exactly why the guard lives on the table, not only
  -- inside compute_salary)
  begin
    update salaries set net = 99999 where technician_id = v_t1p and period = '2026-05-01';
    res := res || E'\n' || 'direct UPDATE on a locked salaries row: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'direct UPDATE on a locked salaries row: rejected ('||sqlerrm||')';
  end;

  -- And a direct DELETE
  begin
    delete from salaries where technician_id = v_t1p and period = '2026-05-01';
    res := res || E'\n' || 'direct DELETE on a locked salaries row: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'direct DELETE on a locked salaries row: rejected ('||sqlerrm||')';
  end;

  -- And a brand new INSERT for the same locked period (addition a)
  begin
    insert into salaries (org_id, technician_id, period, net) values (v_org, v_t1p, '2026-05-01', 1);
    res := res || E'\n' || 'direct INSERT for a different technician, same locked period: SUCCEEDED (bad, if a conflicting row did not already exist)';
  exception when others then
    res := res || E'\n' || 'direct INSERT for a locked period: rejected ('||sqlerrm||')';
  end;

  -- incentives_earned is guarded too (addition b)
  begin
    insert into incentives_earned (org_id, technician_id, is_bike_allowance, amount, period)
      values (v_org, v_t1p, true, 500, '2026-05-01');
    res := res || E'\n' || 'INSERT into incentives_earned for a locked period: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'INSERT into incentives_earned for a locked period: rejected ('||sqlerrm||')';
  end;

  -- A claim verified against a locked period is rejected (the urgent
  -- question answered properly rather than left to the UI)
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 300, v_t1p::text || '/bill.jpg', '2026-05-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform verify_expense_claim(v_claim.id, 300, null);
    res := res || E'\n' || 'verify_expense_claim against a locked period: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'verify_expense_claim against a locked period: rejected ('||sqlerrm||')';
  end;

  -- Reopen requires a reason
  begin
    perform reopen_salary_period(v_org, '2026-05-01', null);
    res := res || E'\n' || 'reopen_salary_period with no reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'reopen_salary_period with no reason: rejected ('||sqlerrm||')';
  end;

  -- Reopen with a reason works, and the previously-blocked actions now succeed
  select * into v_lock from reopen_salary_period(v_org, '2026-05-01', 'test correction');
  res := res || E'\n' || format('reopen_salary_period with a reason: locked=%s reason=%s', v_lock.locked, v_lock.reason);

  perform verify_expense_claim(v_claim.id, 300, null);
  res := res || E'\n' || 'verify_expense_claim now succeeds after reopening: ok';

  select * into v_salary from compute_salary(v_org, v_t1p, '2026-05-01');
  res := res || E'\n' || format('compute_salary now succeeds after reopening, picks up the verified claim (expect maintenance=300): %s', v_salary.maintenance_amount);

  -- Re-lock is audited the same way as the original lock
  perform lock_salary_period(v_org, '2026-05-01');
  select count(*) into v_n from audit_log where table_name = 'salary_period_locks';
  res := res || E'\n' || format('audit_log rows for salary_period_locks across lock+reopen+re-lock (expect 3): %s', v_n);

  -- Reconciliation report runs and returns rows (not asserting specific
  -- counts here — this transaction''s own inserts are rolled back by the
  -- final RAISE, so the live counts it would see mid-transaction aren''t
  -- representative of anything outside this test anyway; just confirming
  -- it executes and is master-gated).
  perform count(*) from audit_reconciliation_report();
  res := res || E'\n' || 'audit_reconciliation_report executes for a master: ok';

  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform audit_reconciliation_report();
    res := res || E'\n' || 'audit_reconciliation_report as a technician: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'audit_reconciliation_report as a technician: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
