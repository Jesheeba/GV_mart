-- ACL guard, CASE13 pattern (from feat/master-time-slots) -- for every
-- function created or redefined by this branch's migrations
-- (20261107100000 through 20261107100500). Rewritten for this review's ACL
-- audit: compute_incentives, compute_salary, submit_expense_claim,
-- verify_expense_claim, technician_km_log_sum, technician_petrol_
-- reference_amount and technician_approx_distance_km are the seven the
-- frontend calls directly and each has a real caller/org check, so
-- `authenticated` IS expected to have EXECUTE and a real call (with
-- garbage arguments) is expected to fail on business logic, never
-- permission. technician_vehicle_on, technician_own_bike_days,
-- technician_expense_claims_total, person_allowance_on, monthly_
-- adjustment_top_up and monthly_adjustment_excluded are internal-only
-- (called only from inside compute_salary/compute_incentives, which
-- already did the real check) and have NO caller/org check of their own,
-- so `authenticated` is expected to have NO EXECUTE on any of them, and a
-- real call is expected to fail with permission denied specifically.
--
-- The pooler/test connection is `postgres`, the owner of every one of
-- these functions -- ownership does not carry through a role switch
-- (verified empirically), but relying on that implicitly, inside other
-- tests that happen to also exercise these functions, is not the same as
-- asserting it. This file asserts it directly.
--
-- Rolled back by its own final RAISE; nothing persists.
do $t$
declare
  res text := '';
  v_sig text;
  v_call text;
  v_expect_granted boolean;
  procs record;
  recs record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

  for recs in
    select * from (values
      ('technician_vehicle_on(uuid,uuid,date)',              $$select technician_vehicle_on(gen_random_uuid(), gen_random_uuid(), current_date)$$,              false),
      ('technician_own_bike_days(uuid,uuid,date)',           $$select technician_own_bike_days(gen_random_uuid(), gen_random_uuid(), current_date)$$,           false),
      ('technician_km_log_sum(uuid,uuid,date)',              $$select technician_km_log_sum(gen_random_uuid(), gen_random_uuid(), current_date)$$,              true),
      ('technician_petrol_reference_amount(uuid,uuid,date)', $$select technician_petrol_reference_amount(gen_random_uuid(), gen_random_uuid(), current_date)$$, true),
      ('technician_approx_distance_km(uuid,uuid,date)',      $$select technician_approx_distance_km(gen_random_uuid(), gen_random_uuid(), current_date)$$,      true),
      ('submit_expense_claim(uuid,text,numeric,text,date)',  $$select submit_expense_claim(gen_random_uuid(), 'petrol', 1, 'x.jpg', current_date)$$,             true),
      ('verify_expense_claim(uuid,numeric,text)',            $$select verify_expense_claim(gen_random_uuid(), 1, null)$$,                                       true),
      ('technician_expense_claims_total(uuid,uuid,date,text)', $$select technician_expense_claims_total(gen_random_uuid(), gen_random_uuid(), current_date, 'petrol')$$, false),
      ('person_allowance_on(uuid,uuid,date)',                $$select person_allowance_on(gen_random_uuid(), gen_random_uuid(), current_date)$$,                false),
      ('monthly_adjustment_top_up(uuid,uuid,date,text)',     $$select monthly_adjustment_top_up(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$, false),
      ('monthly_adjustment_excluded(uuid,uuid,date,text)',   $$select monthly_adjustment_excluded(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$, false),
      ('compute_incentives(uuid,date)',                      $$select compute_incentives(gen_random_uuid(), current_date)$$,                                    true),
      ('compute_salary(uuid,uuid,date)',                     $$select compute_salary(gen_random_uuid(), gen_random_uuid(), current_date)$$,                     true)
    ) as t(sig, call, expect_granted)
  loop
    v_sig := recs.sig;
    v_call := recs.call;
    v_expect_granted := recs.expect_granted;

    if has_function_privilege('authenticated', format('public.%s', v_sig), 'execute') then
      if not v_expect_granted then
        res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated HAS execute, expected none (internal-only, no caller/org check)';
      else
        execute 'set local role authenticated';
        begin
          execute v_call;
          res := res || E'\n' || 'ok   '||v_sig||' -- granted as expected, call unexpectedly succeeded with garbage args (still proves no permission error)';
        exception when others then
          res := res || E'\n' || case
            when sqlerrm ilike '%permission denied%' then 'FAIL '||v_sig||' -- granted, but hit permission denied anyway: '||sqlerrm
            else 'ok   '||v_sig||' -- granted as expected, failed on business logic not permission: '||sqlerrm
          end;
        end;
        execute 'reset role';
      end if;
    else
      if v_expect_granted then
        res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated has NO execute, expected a grant (frontend calls this directly)';
      else
        execute 'set local role authenticated';
        begin
          execute v_call;
          res := res || E'\n' || 'FAIL '||v_sig||' -- not granted, but the call SUCCEEDED anyway (grant check bypassed somehow)';
        exception when others then
          res := res || E'\n' || case
            when sqlerrm ilike '%permission denied%' then 'ok   '||v_sig||' -- correctly ungranted: '||sqlerrm
            else 'FAIL '||v_sig||' -- ungranted but failed on something other than permission denied: '||sqlerrm
          end;
        end;
        execute 'reset role';
      end if;
    end if;
  end loop;

  raise exception E'RESULTS:%', res;
end
$t$;
