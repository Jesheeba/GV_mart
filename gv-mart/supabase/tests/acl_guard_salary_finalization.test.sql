-- ACL guard, CASE13 pattern (from feat/master-time-slots) -- for the
-- functions this branch adds/redefines beyond feat/monthly-expenses
-- (20261024100700 salary_period_locks, 20261024100800 audit_reconciliation_
-- baseline, 20261024100900 audit_reconciliation_cron). audit_reconciliation_
-- report in particular went through a DROP + CREATE in 100800 and another
-- CREATE OR REPLACE in 100900 -- both re-grant explicitly, confirmed below
-- rather than assumed.
--
-- audit_reconciliation_cron_tick and _audit_reconciliation_deadman_check are
-- deliberately cron-only (pg_cron calls them as the job owner, never a
-- logged-in user) -- this asserts the OPPOSITE: authenticated must NOT be
-- able to execute them, to catch an accidental future grant.
--
-- Rolled back by its own final RAISE; nothing persists.
do $t$
declare
  res text := '';
  v_sig text;
  v_call text;
  procs text[][] := array[
    ['is_salary_period_locked(uuid,date)',               $$select is_salary_period_locked(gen_random_uuid(), current_date)$$],
    ['lock_salary_period(uuid,date)',                     $$select lock_salary_period(gen_random_uuid(), current_date)$$],
    ['reopen_salary_period(uuid,date,text)',              $$select reopen_salary_period(gen_random_uuid(), current_date, 'test')$$],
    ['capture_audit_reconciliation_baseline(text)',       $$select capture_audit_reconciliation_baseline('test')$$],
    ['audit_reconciliation_report()',                     $$select count(*) from audit_reconciliation_report()$$],
    ['followup_counts(text,uuid)',                        $$select followup_counts('auto', null)$$]
  ];
  v_row text[];
  v_deny_sig text;
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
      res := res || E'\n' || 'ok   '||v_sig||' -- granted, call unexpectedly succeeded with garbage args';
    exception when others then
      res := res || E'\n' || case
        when sqlerrm ilike '%permission denied%' then 'FAIL '||v_sig||' -- hit permission denied: '||sqlerrm
        else 'ok   '||v_sig||' -- granted, failed on business logic not permission: '||sqlerrm
      end;
    end;
    execute 'reset role';
  end loop;

  -- Negative checks: these two must NOT be callable by authenticated.
  foreach v_deny_sig in array array['audit_reconciliation_cron_tick(text)', '_audit_reconciliation_deadman_check(text)'] loop
    res := res || E'\n' || case
      when has_function_privilege('authenticated', format('public.%s', v_deny_sig), 'execute')
      then 'FAIL '||v_deny_sig||' -- authenticated CAN execute a cron-only function (should be revoked)'
      else 'ok   '||v_deny_sig||' -- correctly not executable by authenticated'
    end;
  end loop;

  raise exception E'RESULTS:%', res;
end
$t$;
