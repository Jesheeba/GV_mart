-- Rolled-back test for migrations/20261015130000_internal_tables_staff_read.sql (runner: migration file, then this block).
-- Each persona reads meeting_logs, meeting_issues and automation_flows of its own organisation; a second organisation's rows must stay invisible.
do $t$
declare
  res text := ''; v_org uuid; v_org2 uuid; v_log uuid; r record; a int; b int; c int;
  v_ids jsonb := '{}'::jsonb; v_u uuid;
begin
  insert into organizations(name) values ('__TEST_internal_read') returning id into v_org;
  insert into organizations(name) values ('__TEST_internal_read_other') returning id into v_org2;
  for r in select * from (values
      ('master','master',true,false),('ops','operation_admin',true,false),('sales','sales_admin',true,false),
      ('ops_inactive','operation_admin',false,false),('technician','technician',true,true),('technician_inactive','technician',true,false),
      ('customer','customer',true,false),('noprofile',null,true,false)) t(n,ro,ac,tech)
  loop
    v_u := gen_random_uuid(); v_ids := v_ids || jsonb_build_object(r.n, v_u);
    insert into auth.users(id,email) values (v_u,'__test_'||v_u||'@example.invalid');
    if r.ro is not null then
      insert into profiles(id,org_id,full_name,role,is_active) values (v_u,v_org,'__TEST_'||r.n,r.ro::user_role,r.ac);
      if r.ro = 'technician' then
        insert into technicians(org_id,profile_id,is_active) values (v_org, v_u, r.tech);
      end if;
    end if;
  end loop;
  insert into meeting_logs(org_id,meeting_date,general_notes) values (v_org,current_date,'__TEST_notes') returning id into v_log;
  insert into meeting_issues(org_id,meeting_id,description,date_raised) values (v_org,v_log,'__TEST_issue',current_date);
  insert into automation_flows(org_id,trigger,action) select v_org, trigger, action from automation_flows limit 1;
  -- other organisation's rows
  insert into meeting_logs(org_id,meeting_date,general_notes) values (v_org2,current_date,'__TEST_other') returning id into v_log;
  insert into meeting_issues(org_id,meeting_id,description,date_raised) values (v_org2,v_log,'__TEST_other_issue',current_date);

  for r in select * from (values
      ('master',1,1,1),('ops',1,1,1),('sales',1,1,1),('technician',1,1,0),
      ('ops_inactive',0,0,0),('technician_inactive',0,0,0),('customer',0,0,0),('noprofile',0,0,0)) e(n,m,i,f)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>r.n)::uuid,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into a from meeting_logs;
    select count(*) into b from meeting_issues;
    select count(*) into c from automation_flows;
    execute 'reset role';
    res := res || E'\n' || case when a=r.m and b=r.i and c=r.f
        then 'ok   '||rpad(r.n,20)||' meeting_logs='||a||' meeting_issues='||b||' automation_flows='||c
        else 'FAIL '||rpad(r.n,20)||' got '||a||'/'||b||'/'||c||' expected '||r.m||'/'||r.i||'/'||r.f end;
  end loop;

  -- writes unchanged: staff can still write, technician and customer still cannot
  perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>'sales')::uuid,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into meeting_logs(org_id,meeting_date,general_notes) values (v_org,current_date + 1,'__TEST_w'); res := res || E'\nok   W1 sales_admin can still write a meeting log';
  exception when others then res := res || E'\nFAIL W1 '||sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>'technician')::uuid,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into meeting_logs(org_id,meeting_date,general_notes) values (v_org,current_date + 2,'__TEST_w2'); res := res || E'\nFAIL W2 technician wrote a meeting log';
  exception when others then res := res || E'\nok   W2 technician still cannot write'; end;
  execute 'reset role';
  raise exception E'RESULTS:%', res;
end
$t$;
