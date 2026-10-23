-- Rolled-back check for 20261024100400_person_allowances_and_adjustments.sql.
-- Run through the Management API (database/query); it always ends in a
-- RAISE so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_profile uuid; v_profile2 uuid; v_row public.person_allowances;
  v_n int; v_base numeric; v_excluded boolean;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_profile from profiles where org_id = v_org limit 1;
  select id into v_profile2 from profiles where org_id = v_org and id <> v_profile limit 1;

  -- A person with no person_allowances row receives no recharge
  select * into v_row from person_allowance_on(v_org, v_profile2, '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s', v_row.id is null);

  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_profile, 300, '2026-01-01');

  -- A top-up with a null reason is rejected by the database
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_profile, '2026-01-01', 'recharge', 'top_up', 200, null);
    res := res || E'\n' || 'top_up with null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'top_up with null reason: rejected ('||sqlerrm||')';
  end;

  -- A top-up with a reason succeeds and sums correctly
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_profile, '2026-01-01', 'recharge', 'top_up', 200, 'extra data plan this month');
  select monthly_adjustment_top_up(v_org, v_profile, '2026-01-01', 'recharge') into v_base;
  res := res || E'\n' || format('recharge top-up total (expect 200): %s', v_base);

  -- An exclusion for one month affects that month only
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_profile, '2026-02-01', 'recharge', 'exclude', null, 'customer complaint, withheld for February');
  select monthly_adjustment_excluded(v_org, v_profile, '2026-02-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('February excluded (expect true): %s', v_excluded);
  select monthly_adjustment_excluded(v_org, v_profile, '2026-01-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('January NOT excluded (expect false): %s', v_excluded);

  -- Ending a person's allowance row stops future months without altering past ones
  update person_allowances set effective_to = '2026-01-31' where profile_id = v_profile;
  select * into v_row from person_allowance_on(v_org, v_profile, '2026-01-15');
  res := res || E'\n' || format('January still resolves (expect 300): %s', v_row.recharge_amount);
  select * into v_row from person_allowance_on(v_org, v_profile, '2026-03-01');
  res := res || E'\n' || format('March after ending the row (expect id is null): %s', v_row.id is null);

  -- An adjustment belonging to another organisation is not visible or applicable
  declare v_other_master uuid;
  begin
    select id into v_other_master from profiles where role='master' and org_id <> v_org limit 1;
    if v_other_master is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_other_master, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into v_n from monthly_adjustments where profile_id = v_profile;
      res := res || E'\n' || format('other-org master sees this org''s adjustments (expect 0): %s', v_n);
      execute 'reset role';
    else
      res := res || E'\n' || 'other-org master check: skipped (no second organisation in this database)';
    end if;
  end;

  raise exception E'RESULTS%', res;
end $t$;
