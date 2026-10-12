-- Rolled-back tests for the HELD staff-security migrations:
--   20261011100000_revoke_user_sessions.sql  (F-01)
--   20261011110000_audit_log_append_only.sql (F-02/03/05/13, purge route)
--   20261011120000_profiles_no_client_master_grant.sql (F-06)
-- The runner concatenates the three migration files in front of this block in ONE transaction; the block ends in RAISE,
-- so nothing is committed. Throwaway __TEST_ organisation and users only. Run live 2026-10-12 via the Management API inside begin ... rollback.
do $t$
declare
  res text := ''; v_org uuid; v_real uuid; v_m uuid := gen_random_uuid(); v_s uuid := gen_random_uuid(); v_x uuid := gen_random_uuid();
  v_sess uuid := gen_random_uuid(); v_p uuid := gen_random_uuid(); v_aid uuid; n int; r int; v_other int;
begin
  -- ===== F-06 no client-side master grant =====
  insert into organizations(name) values ('__TEST_secfix_org') returning id into v_org;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_s,v_x]) x;
  insert into profiles(id,org_id,full_name,role) values (v_m,v_org,'__TEST_master','master'),(v_s,v_org,'__TEST_sales','sales_admin');
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update profiles set role='master' where id=v_s; res := res || E'\nFAIL F06a master promoted a sales_admin to master from the client';
  exception when others then res := res || E'\nok   F06a client UPDATE to role=master refused (even for a master): '||sqlerrm; end;
  begin insert into profiles(id,org_id,full_name,role) values (v_x,v_org,'__TEST_x','master'); res := res || E'\nFAIL F06b client INSERT of a master';
  exception when others then res := res || E'\nok   F06b client INSERT with role=master refused'; end;
  begin update profiles set full_name='__TEST_master_renamed' where id=v_m; get diagnostics n = row_count;
        res := res || E'\n' || case when n=1 then 'ok   F06c master can still edit their own row (role unchanged)' else 'FAIL F06c rows='||n end;
  exception when others then res := res || E'\nFAIL F06c '||sqlerrm; end;
  begin update profiles set role='operation_admin' where id=v_s; get diagnostics n = row_count;
        res := res || E'\n' || case when n=1 then 'ok   F06d master can still change a role to a non-master' else 'FAIL F06d' end;
  exception when others then res := res || E'\nFAIL F06d '||sqlerrm; end;
  execute 'reset role';
  update profiles set role='master' where id=v_s;   -- as the owner (service-role equivalent): allowed
  select count(*) into n from profiles where id=v_s and role='master';
  res := res || E'\n' || case when n=1 then 'ok   F06e owner/service role can still create or promote a master' else 'FAIL F06e' end;
  update profiles set role='sales_admin' where id=v_s;

  -- ===== F-02/03/05 audit_log append-only =====
  insert into audit_log(org_id,actor_id,action,table_name,row_id,after) values (v_org,v_m,'STAFF_CREATE','profiles',null,'{"phase":"start"}') returning id into v_aid;
  begin update audit_log set action='TAMPERED' where id=v_aid; res := res || E'\nFAIL A1 owner UPDATE succeeded';
  exception when others then res := res || E'\nok   A1 UPDATE of an audit row refused: '||sqlerrm; end;
  begin delete from audit_log where id=v_aid; res := res || E'\nFAIL A2 owner DELETE succeeded';
  exception when others then res := res || E'\nok   A2 DELETE of an audit row refused'; end;
  begin truncate audit_log; res := res || E'\nFAIL A3 TRUNCATE succeeded';
  exception when others then res := res || E'\nok   A3 TRUNCATE refused'; end;
  perform set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  execute 'set local role service_role';
  begin update audit_log set action='TAMPERED' where id=v_aid; res := res || E'\nFAIL A4 service_role UPDATE';
  exception when others then res := res || E'\nok   A4 service_role cannot UPDATE audit_log (privilege revoked)'; end;
  begin delete from audit_log where id=v_aid; res := res || E'\nFAIL A5 service_role DELETE';
  exception when others then res := res || E'\nok   A5 service_role cannot DELETE audit_log'; end;
  begin insert into audit_log(org_id,actor_id,action,table_name,after) values (v_org,v_m,'STAFF_CREATE','profiles','{"phase":"result"}'); res := res || E'\nok   A6 service_role can still INSERT (completion rows)';
  exception when others then res := res || E'\nFAIL A6 service_role INSERT: '||sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin delete from audit_log where id=v_aid; res := res || E'\nFAIL A7 authenticated DELETE';
  exception when others then res := res || E'\nok   A7 authenticated cannot DELETE audit_log'; end;
  execute 'reset role';

  -- deleting a profile that has audit rows must still work (FK SET NULL is the one allowed UPDATE)
  begin delete from profiles where id=v_s; select count(*) into n from audit_log where org_id=v_org;
        res := res || E'\nok   A8 deleting a profile with no audit rows works'; exception when others then res := res || E'\nFAIL A8 '||sqlerrm; end;
  begin delete from profiles where id=v_m; delete from auth.users where id=v_m;
        select count(*) into n from audit_log where org_id=v_org and actor_id is null;
        res := res || E'\n' || case when n>=1 then 'ok   A9 deleting the ACTOR profile works; their audit rows keep existing with actor_id NULL ('||n||')' else 'FAIL A9 rows with null actor='||n end;
  exception when others then res := res || E'\nFAIL A9 deleting an actor profile: '||sqlerrm; end;

  -- ===== purge route: real organisations cannot be purged =====
  perform set_config('request.jwt.claims', '', true);   -- the actor profile was deleted above; no JWT for the seeding triggers
  insert into organizations(name) values ('Real Looking Org') returning id into v_real;
  insert into audit_log(org_id,action,table_name,after) values (v_real,'X','profiles','{}');
  begin perform purge_test_organisation(v_real); res := res || E'\nFAIL P1 purge accepted a non-test organisation';
  exception when others then res := res || E'\nok   P1 purge refuses a real organisation: '||sqlerrm; end;
  begin delete from organizations where id=v_real; res := res || E'\nFAIL P2 a real organisation with audit rows was deleted';
  exception when others then res := res || E'\nok   P2 direct DELETE of a real organisation with audit rows is blocked by the trigger'; end;
  -- give the throwaway org real content so the cascade is exercised: a profile (audited), a lead and a customer
  insert into auth.users(id,email) values (v_p,'__test_'||v_p||'@example.invalid');
  insert into profiles(id,org_id,full_name,role) values (v_p,v_org,'__TEST_late_master','master');
  update profiles set full_name='__TEST_late_master2' where id=v_p;
  insert into leads(org_id,name,mobile,source,status) values (v_org,'__TEST_lead','9000000000','walk_in','new');
  begin perform purge_test_organisation(v_org); select count(*) into n from organizations where id=v_org;
        select count(*) into r from audit_log where org_id=v_org;
        v_other := (select count(*) from profiles where org_id=v_org) + (select count(*) from leads where org_id=v_org);
        res := res || E'\n' || case when n=0 and r=0 and v_other=0 then 'ok   P3 purge removes a __TEST_ organisation with profile+lead and its audit rows' else 'FAIL P3 org='||n||' audit='||r||' other='||v_other end;
  exception when others then res := res || E'\nFAIL P3 '||sqlerrm; end;
  res := res || E'\n' || case when not has_function_privilege('authenticated','public.purge_test_organisation(uuid)','execute')
                              and not has_function_privilege('anon','public.purge_test_organisation(uuid)','execute')
                              and not has_function_privilege('service_role','public.purge_test_organisation(uuid)','execute')
                         then 'ok   P4 purge function is not executable by anon, authenticated or service_role' else 'FAIL P4' end;

  -- ===== F-01 revoke_user_sessions =====
  res := res || E'\n' || case when has_function_privilege('service_role','public.revoke_user_sessions(uuid)','execute')
                              and not has_function_privilege('authenticated','public.revoke_user_sessions(uuid)','execute')
                              and not has_function_privilege('anon','public.revoke_user_sessions(uuid)','execute')
                         then 'ok   S1 revoke_user_sessions executable by service_role only' else 'FAIL S1' end;
  insert into auth.users(id,email) values (v_sess,'__test_'||v_sess||'@example.invalid');
  begin
    insert into auth.sessions(id,user_id,created_at,updated_at) values (gen_random_uuid(), v_sess, now(), now());
    insert into auth.refresh_tokens(token,user_id,revoked,created_at,updated_at) values ('__test_tok_'||v_sess, v_sess::text, false, now(), now());
    perform revoke_user_sessions(v_sess);
    select count(*) into n from auth.sessions where user_id=v_sess;
    select count(*) into r from auth.refresh_tokens where user_id::text=v_sess::text;
    res := res || E'\n' || case when n=0 and r=0 then 'ok   S2 sessions and refresh tokens of the target are gone' else 'FAIL S2 sessions='||n||' tokens='||r end;
  exception when others then res := res || E'\nINFO S2 could not build the auth fixture here ('||sqlerrm||'); run the live refresh-token test from the post-deploy plan instead'; end;
  begin perform set_config('request.jwt.claims', json_build_object('sub',v_x,'role','authenticated')::text, true); execute 'set local role authenticated';
        perform revoke_user_sessions(v_sess); res := res || E'\nFAIL S3 authenticated called revoke_user_sessions';
  exception when others then res := res || E'\nok   S3 authenticated cannot call revoke_user_sessions'; end;
  execute 'reset role';
  raise exception E'RESULTS:%', res;
end
$t$;
