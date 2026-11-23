-- Rolled-back test for 20261213100000_login_activity.sql. Test IDs map to build-docs/features/login-activity.md
-- acceptance criteria (AC1..AC8). The runner puts the migration in front of this block in ONE transaction; this block
-- ALWAYS ends in RAISE EXCEPTION, so nothing is ever committed. Throwaway __TEST_ organisations and users only.
do $t$
declare
  res text := ''; n int; r record;
  v_org uuid; v_org2 uuid;
  v_m uuid := gen_random_uuid(); v_s uuid := gen_random_uuid(); v_tech uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid(); v_m2 uuid := gen_random_uuid();
  s_m uuid := gen_random_uuid(); s_c uuid := gen_random_uuid(); s_tech uuid := gen_random_uuid();
  s_m2 uuid := gen_random_uuid(); s_fail uuid := gen_random_uuid(); s_old uuid := gen_random_uuid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  insert into public.organizations(name) values ('__TEST_login_activity') returning id into v_org;
  insert into public.organizations(name) values ('__TEST_login_activity_other') returning id into v_org2;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_s,v_tech,v_c,v_m2]) x;
  insert into public.profiles(id,org_id,full_name,role,phone) values
    (v_m,v_org,'__TEST_master','master','9000000101'),
    (v_s,v_org,'__TEST_sales','sales_admin','9000000102'),
    (v_tech,v_org,'__TEST_tech','technician','9000000103'),
    (v_c,v_org,'__TEST_cust_50%','customer','9000000104'),
    (v_m2,v_org2,'__TEST_master_other','master','9000000105');

  -- ===== structure (AC6) =====
  res := res || E'\n' || case when (select relrowsecurity from pg_class where oid='public.login_sessions'::regclass)
                              and not exists (select 1 from pg_policies where schemaname='public' and tablename='login_sessions')
                         then 'ok   S1 RLS on, no policies' else 'FAIL S1' end;
  res := res || E'\n' || case when not has_table_privilege('authenticated','public.login_sessions','SELECT')
                              and not has_table_privilege('anon','public.login_sessions','SELECT')
                              and not has_table_privilege('authenticated','public.login_sessions','INSERT')
                         then 'ok   S2 anon/authenticated have no table privileges' else 'FAIL S2' end;
  res := res || E'\n' || case when not has_function_privilege('anon','public.list_login_activity(date,date,text,text,int,int)','EXECUTE')
                              and has_function_privilege('authenticated','public.list_login_activity(date,date,text,text,int,int)','EXECUTE')
                              and not has_function_privilege('authenticated','public.purge_login_sessions()','EXECUTE')
                              and not has_function_privilege('anon','public.purge_login_sessions()','EXECUTE')
                         then 'ok   S3 function grants: RPC authenticated only, purge internal only' else 'FAIL S3' end;
  select count(*) into n from pg_trigger where tgrelid='auth.sessions'::regclass and tgname like 'login_sessions_capture_%';
  res := res || E'\n' || case when n=3 then 'ok   S4 3 capture triggers on auth.sessions' else 'FAIL S4 n='||n end;
  select count(*) into n from cron.job where jobname='purge-login-sessions' and schedule='0 21 * * *';
  res := res || E'\n' || case when n=1 then 'ok   S5 purge cron scheduled' else 'FAIL S5 n='||n end;

  -- ===== capture (AC1, AC2) =====
  insert into auth.sessions(id,user_id,created_at,updated_at,user_agent) values
    (s_m, v_m, now(), now(), 'Mozilla/5.0 (Windows NT 10.0) Chrome/130'),
    (s_c, v_c, now(), now(), 'Mozilla/5.0 (Linux; Android 14; wv)'),
    (s_tech, v_tech, now(), now(), null),
    (s_m2, v_m2, now(), now(), null);
  select * into r from public.login_sessions where session_id=s_m;
  res := res || E'\n' || case when r.user_id=v_m and r.org_id=v_org and r.role='master' and r.started_at is not null
                              and r.ended_at is null and r.user_agent like 'Mozilla%'
                         then 'ok   AC1a sign-in creates one row with user/org/role/start/device' else 'FAIL AC1a' end;
  select count(*) into n from public.login_sessions where session_id in (s_m,s_c,s_tech,s_m2);
  res := res || E'\n' || case when n=4 then 'ok   AC1b one row per session' else 'FAIL AC1b n='||n end;

  update public.login_sessions set last_seen_at = now() - interval '1 hour' where session_id=s_m;
  update auth.sessions set refreshed_at = (now() at time zone 'UTC') where id=s_m;
  select count(*) into n from public.login_sessions where session_id=s_m and last_seen_at > now() - interval '1 minute';
  res := res || E'\n' || case when n=1 then 'ok   AC1c token refresh updates last_seen_at' else 'FAIL AC1c' end;

  delete from auth.sessions where id=s_tech;
  select count(*) into n from public.login_sessions where session_id=s_tech and ended_at is not null;
  res := res || E'\n' || case when n=1 then 'ok   AC2a sign-out sets ended_at' else 'FAIL AC2a' end;

  perform public.revoke_user_sessions(v_c);
  select count(*) into n from public.login_sessions where session_id=s_c and ended_at is not null;
  res := res || E'\n' || case when n=1 then 'ok   AC2b password-reset eviction sets ended_at' else 'FAIL AC2b' end;

  -- ===== a broken logger never blocks a login (AC3) =====
  alter table public.login_sessions add constraint __test_force_fail check (false) not valid;
  begin
    insert into auth.sessions(id,user_id,created_at,updated_at) values (s_fail, v_s, now(), now());
    select count(*) into n from auth.sessions where id=s_fail;
    res := res || E'\n' || case when n=1 and not exists (select 1 from public.login_sessions where session_id=s_fail)
                           then 'ok   AC3 failing capture still lets the session (login) commit' else 'FAIL AC3' end;
  exception when others then res := res || E'\nFAIL AC3 login blocked: '||sqlerrm; end;
  alter table public.login_sessions drop constraint __test_force_fail;
  delete from auth.sessions where id=s_fail;

  -- ===== read RPC as master (AC4, AC5, AC7) =====
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'all', '__TEST_', 200, 0);
  res := res || E'\n' || case when n=3 then 'ok   AC4 master sees staff+technician+customer of own org' else 'FAIL AC4 n='||n end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'all', '__TEST_master_other', 200, 0);
  res := res || E'\n' || case when n=0 then 'ok   AC7 master never sees another org' else 'FAIL AC7 n='||n end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'customer', '__TEST_', 200, 0) where role='customer';
  res := res || E'\n' || case when n=1 and (select count(*) from public.list_login_activity(v_today - 1, v_today, 'customer', '__TEST_', 200, 0))=1
                         then 'ok   AC5a role filter customer' else 'FAIL AC5a' end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'staff', '__TEST_', 200, 0);
  res := res || E'\n' || case when n=1 then 'ok   AC5b role filter staff' else 'FAIL AC5b n='||n end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'all', '9000000103', 200, 0);
  res := res || E'\n' || case when n=1 then 'ok   AC5c search by phone' else 'FAIL AC5c n='||n end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'all', '_cust_50%', 200, 0);
  res := res || E'\n' || case when n=1 and (select count(*) from public.list_login_activity(v_today - 1, v_today, 'all', 'TEST%master', 200, 0))=0
                         then 'ok   AC5d LIKE wildcards matched literally' else 'FAIL AC5d n='||n end;
  select count(*) into n from public.list_login_activity(v_today - 10, v_today - 5, 'all', '__TEST_', 200, 0);
  res := res || E'\n' || case when n=0 then 'ok   AC5e date range excludes out-of-range logins' else 'FAIL AC5e n='||n end;
  select count(*), max(total_count) into r from public.list_login_activity(v_today - 1, v_today, 'all', '__TEST_', 2, 0);
  res := res || E'\n' || case when r.count=2 and r.max=3 then 'ok   AC5f page size + total_count' else 'FAIL AC5f' end;
  select count(*) into n from public.list_login_activity(v_today - 1, v_today, 'all', '__TEST_', 2, 2);
  res := res || E'\n' || case when n=1 then 'ok   AC5g offset returns the next page' else 'FAIL AC5g n='||n end;

  begin perform public.list_login_activity(v_today, v_today - 1, 'all', null, 50, 0); res := res || E'\nFAIL V1 from>to accepted';
  exception when others then res := res || E'\nok   V1 from>to rejected'; end;
  begin perform public.list_login_activity(v_today - 400, v_today, 'all', null, 50, 0); res := res || E'\nFAIL V2 >366 days accepted';
  exception when others then res := res || E'\nok   V2 range >366 days rejected'; end;
  begin perform public.list_login_activity(v_today, v_today, 'all', null, 500, 0); res := res || E'\nFAIL V3 limit 500 accepted';
  exception when others then res := res || E'\nok   V3 limit >200 rejected'; end;
  begin perform public.list_login_activity(v_today, v_today, 'hacker', null, 50, 0); res := res || E'\nFAIL V4 bad role accepted';
  exception when others then res := res || E'\nok   V4 bad role filter rejected'; end;

  begin perform 1 from public.login_sessions limit 1; res := res || E'\nFAIL AC6a direct select allowed';
  exception when insufficient_privilege then res := res || E'\nok   AC6a direct table select denied'; end;

  -- ===== non-master callers (AC6) =====
  perform set_config('request.jwt.claims', json_build_object('sub',v_s,'role','authenticated')::text, true);
  begin perform public.list_login_activity(v_today, v_today, 'all', null, 50, 0); res := res || E'\nFAIL AC6b sales_admin allowed';
  exception when others then res := res || E'\nok   AC6b sales_admin rejected'; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_tech,'role','authenticated')::text, true);
  begin perform public.list_login_activity(v_today, v_today, 'all', null, 50, 0); res := res || E'\nFAIL AC6c technician allowed';
  exception when others then res := res || E'\nok   AC6c technician rejected'; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_c,'role','authenticated')::text, true);
  begin perform public.list_login_activity(v_today, v_today, 'all', null, 50, 0); res := res || E'\nFAIL AC6d customer allowed';
  exception when others then res := res || E'\nok   AC6d customer rejected'; end;
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  begin perform public.list_login_activity(v_today, v_today, 'all', null, 50, 0); res := res || E'\nFAIL AC6e anon allowed';
  exception when others then res := res || E'\nok   AC6e anon rejected'; end;
  execute 'reset role';

  -- ===== retention =====
  insert into public.login_sessions(session_id,user_id,org_id,role,started_at) values (s_old, v_m, v_org, 'master', now() - interval '91 days');
  perform public.purge_login_sessions();
  res := res || E'\n' || case when not exists (select 1 from public.login_sessions where session_id=s_old)
                              and exists (select 1 from public.login_sessions where session_id=s_m)
                         then 'ok   R1 purge removes >90-day rows, keeps recent' else 'FAIL R1' end;

  raise exception E'RESULTS:%', res;
end
$t$;
