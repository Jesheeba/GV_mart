-- ACL guard, CASE13 pattern (from feat/master-time-slots) -- for every
-- function created or redefined by this branch's migrations
-- (20261024100100 through 20261024100600). The pooler/test connection is
-- `postgres`, the owner of every one of these functions -- ownership does
-- not carry through a role switch (verified empirically), but relying on
-- that implicitly, inside other tests that happen to also exercise these
-- functions, is not the same as asserting it. This file asserts it
-- directly: has_function_privilege('authenticated', ..., 'execute') must be
-- true, and a real call under SET ROLE authenticated must fail (if it fails
-- at all) on business logic, never on "permission denied".
--
-- Rolled back by its own final RAISE; nothing persists.
do $t$
declare
  res text := '';
  v_sig text;
  v_call text;
  procs text[][] := array[
    ['technician_vehicle_on(uuid,uuid,date)',            $$select technician_vehicle_on(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_own_bike_days(uuid,uuid,date)',         $$select technician_own_bike_days(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_km_log_sum(uuid,uuid,date)',            $$select technician_km_log_sum(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_petrol_reference_amount(uuid,uuid,date)', $$select technician_petrol_reference_amount(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_approx_distance_km(uuid,uuid,date)',    $$select technician_approx_distance_km(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['submit_expense_claim(uuid,text,numeric,text,date)', $$select submit_expense_claim(gen_random_uuid(), 'petrol', 1, 'x.jpg', current_date)$$],
    ['verify_expense_claim(uuid,numeric,text)',          $$select verify_expense_claim(gen_random_uuid(), 1, null)$$],
    ['technician_expense_claims_total(uuid,uuid,date,text)', $$select technician_expense_claims_total(gen_random_uuid(), gen_random_uuid(), current_date, 'petrol')$$],
    ['person_allowance_on(uuid,uuid,date)',              $$select person_allowance_on(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['monthly_adjustment_top_up(uuid,uuid,date,text)',   $$select monthly_adjustment_top_up(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$],
    ['monthly_adjustment_excluded(uuid,uuid,date,text)', $$select monthly_adjustment_excluded(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$],
    ['compute_incentives(uuid,date)',                    $$select compute_incentives(gen_random_uuid(), current_date)$$],
    ['compute_salary(uuid,uuid,date)',                   $$select compute_salary(gen_random_uuid(), gen_random_uuid(), current_date)$$]
  ];
  v_row text[];
begin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

  foreach v_row slice 1 in array procs loop
    v_sig := v_row[1];
    v_call := v_row[2];

    if not has_function_privilege('authenticated', format('public.%s', v_sig), 'execute') then
      res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated has NO execute grant';
      continue;
    end if;

    execute 'set local role authenticated';
    begin
      execute v_call;
      res := res || E'\n' || 'ok   '||v_sig||' -- granted, call unexpectedly succeeded with garbage args (still proves no permission error)';
    exception when others then
      res := res || E'\n' || case
        when sqlerrm ilike '%permission denied%' then 'FAIL '||v_sig||' -- hit permission denied: '||sqlerrm
        else 'ok   '||v_sig||' -- granted, failed on business logic not permission: '||sqlerrm
      end;
    end;
    execute 'reset role';
  end loop;

  raise exception E'RESULTS:%', res;
end
$t$;
