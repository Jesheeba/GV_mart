-- Rolled-back check for 20261107100300_person_allowances_and_adjustments.sql.
-- Creates its own __TEST_ organisation, master, 7 technicians and a
-- settings row -- never reads from or depends on whatever real data
-- already exists. Run through the Management API (database/query); it
-- always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
--
-- person_allowance_on / monthly_adjustment_top_up / monthly_adjustment_
-- excluded are internal-only after the ACL audit (no grant to public,
-- anon OR authenticated at all -- only their owner, and the SECURITY
-- DEFINER functions that call them internally, can invoke them). The
-- logic checks below therefore run on the raw connection (no role switch:
-- the Management API connection is not subject to RLS or EXECUTE grants
-- at all), exactly how compute_salary/compute_incentives would reach them
-- internally. Only the final cross-org visibility check switches role,
-- since that checks a table's RLS policy, not a function grant.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_org2 uuid; v_master2 uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_row public.person_allowances;
  v_n int; v_base numeric; v_excluded boolean;
begin
  insert into organizations (name) values ('__TEST_person_allowances') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'pa-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('pa-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_techp[i];
  end loop;

  -- A second organisation, for the cross-org visibility check at the end --
  -- also self-created, not picked from whatever real orgs exist.
  insert into organizations (name) values ('__TEST_person_allowances_other') returning id into v_org2;
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'pa-master2@test.invalid')
    returning id into v_master2;
  insert into profiles (id, org_id, full_name, role) values (v_master2, v_org2, '__TEST_ master2', 'master');

  -- A person with no person_allowances row receives no recharge
  select * into v_row from person_allowance_on(v_org, v_tech[2], '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s', v_row.id is null);

  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_tech[1], 300, '2026-01-01');

  -- A top-up with a null reason is rejected by the database
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_tech[1], '2026-01-01', 'recharge', 'top_up', 200, null);
    res := res || E'\n' || 'top_up with null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'top_up with null reason: rejected ('||sqlerrm||')';
  end;

  -- A top-up with a reason succeeds and sums correctly
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[1], '2026-01-01', 'recharge', 'top_up', 200, 'extra data plan this month');
  select monthly_adjustment_top_up(v_org, v_tech[1], '2026-01-01', 'recharge') into v_base;
  res := res || E'\n' || format('recharge top-up total (expect 200): %s', v_base);

  -- An exclusion for one month affects that month only
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tech[1], '2026-02-01', 'recharge', 'exclude', null, 'customer complaint, withheld for February');
  select monthly_adjustment_excluded(v_org, v_tech[1], '2026-02-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('February excluded (expect true): %s', v_excluded);
  select monthly_adjustment_excluded(v_org, v_tech[1], '2026-01-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('January NOT excluded (expect false): %s', v_excluded);

  -- Ending a person's allowance row stops future months without altering past ones
  update person_allowances set effective_to = '2026-01-31' where profile_id = v_tech[1];
  select * into v_row from person_allowance_on(v_org, v_tech[1], '2026-01-15');
  res := res || E'\n' || format('January still resolves (expect 300): %s', v_row.recharge_amount);
  select * into v_row from person_allowance_on(v_org, v_tech[1], '2026-03-01');
  res := res || E'\n' || format('March after ending the row (expect id is null): %s', v_row.id is null);

  -- ACL audit: none of the three functions above is granted to
  -- authenticated at all (internal-only) -- a direct RPC call as any real
  -- authenticated session, even master, must fail on permission, not
  -- business logic.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform person_allowance_on(v_org, v_tech[1], '2026-01-15');
    res := res || E'\n' || 'master calls person_allowance_on directly as authenticated: SUCCEEDED (bad, should have no grant)';
  exception when others then
    res := res || E'\n' || 'master calls person_allowance_on directly as authenticated: rejected ('||sqlerrm||')';
  end;

  -- An adjustment belonging to another organisation is not visible or
  -- applicable -- this one checks the table's RLS policy, not a function
  -- grant, so the role switch is meaningful here.
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from monthly_adjustments where profile_id = v_tech[1];
  res := res || E'\n' || format('other-org master sees this org''s adjustments (expect 0): %s', v_n);
  execute 'reset role';

  -- CROSS-ORG CHECKS (write_ops existence checks, this review's fix):
  -- master (ops staff of v_org) tries to insert tagged with org_id = v_org
  -- (their own org) but profile_id = v_master2, a real profile that
  -- belongs to v_org2. Before this fix, neither write_ops policy verified
  -- that relationship at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
      values (v_org, v_master2, 300, '2026-04-01');
    res := res || E'\n' || 'CROSS-ORG person_allowances: master inserts for a profile from a different org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG person_allowances: master inserts for a profile from a different org: rejected ('||sqlerrm||')';
  end;
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_master2, '2026-04-01', 'recharge', 'top_up', 100, 'cross-org check');
    res := res || E'\n' || 'CROSS-ORG monthly_adjustments: master inserts for a profile from a different org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG monthly_adjustments: master inserts for a profile from a different org: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
