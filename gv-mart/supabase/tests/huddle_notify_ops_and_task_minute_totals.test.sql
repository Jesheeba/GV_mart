-- DB tests for 20261109100000_huddle_notify_ops_and_task_minute_totals. NOT RUN (written for review). Run only through the approved
-- rehearsal wrapper (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tp uuid; v_tech uuid; v_m2 uuid;
  v_issue uuid; v_task uuid; v_task2 uuid; s text; n int; v_base text; v_now text;
begin
  insert into organizations (name) values ('__TEST_huddlenotify') returning id into v_org;
  insert into organizations (name) values ('__TEST_huddlenotify_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;

  -- ---------- structure ----------
  perform pg_temp.chk('_trg_meeting_issue_notify is SECURITY DEFINER with a fixed search_path (unchanged privilege shape)',
    (select prosecdef and coalesce(proconfig::text like '%search_path=%', false) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_trg_meeting_issue_notify'));
  perform pg_temp.chk('the two new views exist and are not directly writable by anyone',
    to_regclass('public.task_minute_totals') is not null and to_regclass('public.person_minute_totals') is not null
    and not has_table_privilege('authenticated', 'public.task_minute_totals', 'INSERT')
    and not has_table_privilege('authenticated', 'public.person_minute_totals', 'INSERT')
    and not has_table_privilege('anon', 'public.task_minute_totals', 'SELECT')
    and not has_table_privilege('anon', 'public.person_minute_totals', 'SELECT'));
  perform pg_temp.chk('both views are security_invoker (so RLS on task_logs/tasks runs as the caller, not the view owner)',
    (select count(*) from pg_class where relname in ('task_minute_totals', 'person_minute_totals') and relnamespace = 'public'::regnamespace
       and reloptions is not null and array_to_string(reloptions, ',') like '%security_invoker=true%') = 2);

  -- ---------- item 3: raising a problem notifies BOTH master and operation_admin, not sales_admin ----------
  perform pg_temp.as_user(v_tp);
  select public.raise_huddle_issue('  The van GPS keeps dropping off during jobs  ') into v_issue;
  perform pg_temp.as_pg();
  select count(*) into n from notifications where org_id = v_org and user_id = v_master and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('master is notified when a problem is raised', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('REGRESSION FIX item 3: operation_admin is ALSO notified when a problem is raised (was master-only)', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_sales and type = 'huddle_problem_raised' and ref_id = v_issue;
  perform pg_temp.chk('sales_admin is not notified (only master and operation_admin)', n = 0, n::text);

  -- ---------- a solution and then solved: both master and operation_admin are told each time ----------
  perform pg_temp.as_user(v_sales);
  perform public.propose_huddle_solution(v_issue, 'Replaced the GPS unit and retested on a 20km route');
  perform pg_temp.as_pg();
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_solution_given' and ref_id = v_issue;
  perform pg_temp.chk('operation_admin is notified when a solution is given', n = 1, n::text);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update meeting_issues set status = 'solved', date_solved = current_date where id = %L$q$, v_issue));
  perform pg_temp.as_pg();
  perform pg_temp.chk('the update itself succeeds', s is null, coalesce(s, 'ok'));
  select count(*) into n from notifications where org_id = v_org and user_id = v_ops and type = 'huddle_issue_solved' and ref_id = v_issue;
  perform pg_temp.chk('operation_admin is notified when the issue is marked solved', n = 1, n::text);
  select count(*) into n from notifications where org_id = v_org and user_id = v_master and type = 'huddle_issue_solved' and ref_id = v_issue;
  perform pg_temp.chk('master is still notified when the issue is marked solved', n = 1, n::text);
  perform pg_temp.chk('raised_by/solved_by/solution_by are stamped (acceptance criteria 3)',
    (select raised_by = v_tp and solution_by = v_sales and solved_by = v_sales from meeting_issues where id = v_issue));

  -- ---------- item 5: total minutes, per task and per person ----------
  insert into tasks (org_id, assignee_id, assigned_by, title) values (v_org, v_tp, v_master, '__TEST_ task A') returning id into v_task;
  insert into tasks (org_id, assignee_id, assigned_by, title) values (v_org, v_tp, v_master, '__TEST_ task B') returning id into v_task2;
  insert into task_logs (org_id, task_id, kind, minutes_spent) values (v_org, v_task, 'note', 30), (v_org, v_task, 'note', 45), (v_org, v_task2, 'note', 20);
  perform pg_temp.as_user(v_ops);
  select total_minutes into n from task_minute_totals where task_id = v_task;
  perform pg_temp.chk('per-task total sums every log entry for that task', n = 75, n::text);
  select total_minutes into n from person_minute_totals where profile_id = v_tp;
  perform pg_temp.chk('per-person total sums every task the person is assigned', n = 95, n::text);
  perform pg_temp.as_pg();

  -- ---------- security_invoker actually isolates by org (the reason it was added) ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from task_minute_totals;
  perform pg_temp.chk('a different organisation''s master sees no task_minute_totals rows at all (security_invoker; views do not bypass RLS)', n = 0, n::text);
  select count(*) into n from person_minute_totals;
  perform pg_temp.chk('and no person_minute_totals rows either', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- org scope on the huddle notification itself ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from notifications where ref_id = v_issue;
  perform pg_temp.chk('another organisation''s master was never notified about this organisation''s huddle issue', n = 0, n::text);
  perform pg_temp.as_pg();

  -- ---------- real data: relative to the baseline the wrapper took before the migration ----------
  begin
    v_base := current_setting('gv.baseline', true);
    v_now := pg_temp.gv_fingerprint();
    perform pg_temp.chk('the REAL organisations'' notifications/meeting_issues/task_logs are unchanged by the migration and these tests',
      v_base is not null and v_base = v_now, coalesce(left(v_base, 40), 'no baseline') || ' / ' || coalesce(left(v_now, 40), '-'));
  exception when undefined_function then
    perform pg_temp.chk('real-data fingerprint skipped: this file was not run through the wrapper (no baseline)', true);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
