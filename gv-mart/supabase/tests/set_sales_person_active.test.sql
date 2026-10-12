-- Rolled-back test for held/20261015150000_set_sales_person_active.sql. Runner: [optional held/20261010120000_lead_distribute_pending.sql],
-- the migration, then this block. Throwaway __TEST_ organisations only. The distribution assertions run only when that function exists.
do $t$
declare
  res text := ''; v_org uuid; v_org2 uuid; v_m uuid := gen_random_uuid(); v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid(); v_tech uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_m2 uuid := gen_random_uuid();
  v_cust uuid; v_l1 uuid; v_l2 uuid; v_l3 uuid; v_won uuid; v_lb uuid; j jsonb; n int; v_task_done uuid; v_task_b uuid; v_lead_f uuid;
  has_dist boolean := to_regprocedure('public._lead_distribute_pending(uuid)') is not null;
begin
  insert into organizations(name) values ('__TEST_setactive') returning id into v_org;
  insert into organizations(name) values ('__TEST_setactive_other') returning id into v_org2;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_a,v_b,v_o,v_tech,v_f,v_m2]) x;
  insert into profiles(id,org_id,full_name,role,is_active,receives_new_leads) values
    (v_m,v_org,'__TEST_master','master',true,false),(v_a,v_org,'__TEST_salesA','sales_admin',true,true),(v_b,v_org,'__TEST_salesB','sales_admin',true,true),
    (v_o,v_org,'__TEST_ops','operation_admin',true,false),(v_tech,v_org,'__TEST_tech','technician',true,false),
    (v_f,v_org2,'__TEST_foreign_sales','sales_admin',true,true),(v_m2,v_org,'__TEST_master2','master',true,false);
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_c','9000000001') returning id into v_cust;

  perform set_config('app.lead_assign_ok','1',true);
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org,'__TEST_l1','9000000011','walk_in','new',v_a) returning id into v_l1;
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org,'__TEST_l2','9000000012','walk_in','contacted',v_a) returning id into v_l2;
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org,'__TEST_l3','9000000013','walk_in','quoted',v_a) returning id into v_l3;
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org,'__TEST_won','9000000014','walk_in','won',v_a) returning id into v_won;
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org,'__TEST_lb','9000000015','walk_in','new',v_b) returning id into v_lb;
  insert into leads(org_id,name,mobile,source,status,assigned_to) values (v_org2,'__TEST_lf','9000000016','walk_in','new',v_f) returning id into v_lead_f;
  perform set_config('app.lead_assign_ok','',true);

  -- follow-ups: two open for A (one on a lead, one post-service-style on a lead too: lead XOR ticket), one done for A, one open for B
  delete from lead_followups where lead_id in (v_l1,v_l2,v_l3,v_won,v_lb,v_lead_f);
  insert into lead_followups(org_id,lead_id,due_at,type,status,assigned_to) values
    (v_org,v_l1,now()+interval '1 day','call','open',v_a),(v_org,v_l2,now()+interval '1 day','call','open',v_a),
    (v_org,v_lb,now()+interval '1 day','call','open',v_b);
  insert into lead_followups(org_id,lead_id,due_at,type,status,assigned_to,completed_at) values (v_org,v_l3,now(),'call','done',v_a,now());
  -- tasks: 2 open + 1 rolled + 1 recurring for A, 1 done for A, 1 open for B
  insert into tasks(org_id,assignee_id,title,status,due_date) values
    (v_org,v_a,'__TEST_t1','open',current_date),(v_org,v_a,'__TEST_t2','open',current_date),(v_org,v_a,'__TEST_t3','rolled',current_date);
  insert into tasks(org_id,assignee_id,title,status,due_date,is_recurring) values (v_org,v_a,'__TEST_rec','open',current_date,true);
  insert into tasks(org_id,assignee_id,title,status,due_date) values (v_org,v_a,'__TEST_done','done',current_date) returning id into v_task_done;
  insert into tasks(org_id,assignee_id,title,status,due_date) values (v_org,v_b,'__TEST_tb','open',current_date) returning id into v_task_b;

  -- ===== privilege =====
  res := res || E'\n' || case when has_function_privilege('service_role','public.set_sales_person_active(uuid,uuid,boolean)','execute')
                              and not has_function_privilege('authenticated','public.set_sales_person_active(uuid,uuid,boolean)','execute')
                              and not has_function_privilege('anon','public.set_sales_person_active(uuid,uuid,boolean)','execute')
                         then 'ok   P1 executable by service_role only' else 'FAIL P1' end;

  -- ===== refusals (as service_role) =====
  perform set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  execute 'set local role service_role';
  begin perform set_sales_person_active(v_o, v_a, false); res := res || E'\nFAIL R1 non-master actor accepted';
  exception when others then res := res || E'\nok   R1 actor must be an active master'; end;
  begin perform set_sales_person_active(v_m, v_m2, false); res := res || E'\nFAIL R2 master target accepted';
  exception when others then res := res || E'\nok   R2 a master cannot be changed here'; end;
  begin perform set_sales_person_active(v_m, v_m, false); res := res || E'\nFAIL R3 self accepted';
  exception when others then res := res || E'\nok   R3 the actor cannot target themselves'; end;
  begin perform set_sales_person_active(v_m, v_f, false); res := res || E'\nFAIL R4 other organisation accepted';
  exception when others then res := res || E'\nok   R4 another organisation''s person refused'; end;
  begin perform set_sales_person_active(v_m, v_tech, false); res := res || E'\nFAIL R5 technician accepted';
  exception when others then res := res || E'\nok   R5 only a sales person can be changed here'; end;
  begin perform set_sales_person_active(v_m, v_o, false); res := res || E'\nFAIL R6 operation_admin accepted';
  exception when others then res := res || E'\nok   R6 operation_admin refused (out of scope for v1)'; end;

  -- ===== deactivate A =====
  j := set_sales_person_active(v_m, v_a, false);
  execute 'reset role';
  res := res || E'\n' || case when (j->>'changed')::boolean and (j->>'leads_unassigned')::int = 3 and (j->>'followups_to_master')::int = 2
                              and (j->>'tasks_to_master')::int = 4
                         then 'ok   D1 counts: 3 leads, 2 follow-ups, 4 tasks ('||j::text||')' else 'FAIL D1 '||j::text end;
  select count(*) into n from leads where id in (v_l1,v_l2,v_l3) and assigned_to is null and auto_assign_pending;
  res := res || E'\n' || case when n=3 then 'ok   D2 the 3 open leads are unassigned' else 'FAIL D2 n='||n end;
  select count(*) into n from leads where id in (v_l1,v_l2,v_l3) and (assigned_to is not null) ;
  if has_dist then
    res := res || E'\n' || case when n=0 then 'ok   D2b auto-assign OFF: still unassigned and waiting' else 'FAIL D2b n='||n end;
  end if;
  select count(*) into n from leads where id in (v_l1,v_l2,v_l3) and auto_assign_pending;
  res := res || E'\n' || case when n=3 then 'ok   D3 flagged "needs reassignment" (auto_assign_pending)' else 'FAIL D3 flagged='||n end;
  res := res || E'\n' || case when (select assigned_to from leads where id=v_won)=v_a and not (select auto_assign_pending from leads where id=v_won)
                         then 'ok   D4 won lead untouched' else 'FAIL D4' end;
  res := res || E'\n' || case when (select assigned_to from leads where id=v_lb)=v_b and (select assigned_to from leads where id=v_lead_f)=v_f
                         then 'ok   D5 another person''s and another organisation''s leads untouched' else 'FAIL D5' end;
  select count(*) into n from lead_assignments where lead_id in (v_l1,v_l2,v_l3) and reason='deactivated' and from_user=v_a and to_user is null and assigned_by=v_m;
  res := res || E'\n' || case when n=3 then 'ok   D6 three lead_assignments rows (reason deactivated, assigned_by the master)' else 'FAIL D6 n='||n end;
  select count(*) into n from lead_followups where assigned_to=v_m and status='open' and lead_id in (v_l1,v_l2);
  res := res || E'\n' || case when n=2 and (select count(*) from lead_followups where assigned_to=v_a and status='done')=1
                              and (select assigned_to from lead_followups where lead_id=v_lb)=v_b
                         then 'ok   D7 open follow-ups on the master; the done one and B''s untouched' else 'FAIL D7 n='||n end;
  select count(*) into n from tasks where assignee_id=v_m and title like '\_\_TEST\_%' escape '\';
  res := res || E'\n' || case when n=4 and (select assignee_id from tasks where id=v_task_done)=v_a and (select assignee_id from tasks where id=v_task_b)=v_b
                         then 'ok   D8 open/rolled/recurring tasks on the master; done task and B''s untouched' else 'FAIL D8 n='||n end;
  res := res || E'\n' || case when not (select is_active from profiles where id=v_a) then 'ok   D9 profile is inactive' else 'FAIL D9' end;

  -- idempotent
  execute 'set local role service_role';
  j := set_sales_person_active(v_m, v_a, false);
  execute 'reset role';
  res := res || E'\n' || case when not (j->>'changed')::boolean and (j->>'leads_unassigned')::int = 0 then 'ok   I1 repeating the deactivation changes nothing' else 'FAIL I1 '||j::text end;

  -- ===== client side door is closed =====
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update profiles set is_active = true where id = v_a; res := res || E'\nFAIL C1 master re-activated a sales person from the client';
  exception when others then res := res || E'\nok   C1 client-side is_active change on a sales_admin refused'; end;
  begin update profiles set is_active = false where id = v_o; res := res || E'\nok   C2 operation_admin active flag still editable from the client (out of scope)';
  exception when others then res := res || E'\nFAIL C2 '||sqlerrm; end;
  begin update profiles set is_active = false where id = v_tech; res := res || E'\nok   C3 technician active flag still editable from the client';
  exception when others then res := res || E'\nFAIL C3 '||sqlerrm; end;
  begin perform set_sales_person_active(v_m, v_b, false); res := res || E'\nFAIL C4 authenticated called the function';
  exception when others then res := res || E'\nok   C4 authenticated cannot call the function'; end;
  execute 'reset role';

  -- ===== reactivate: nothing handed back =====
  execute 'set local role service_role';
  j := set_sales_person_active(v_m, v_a, true);
  execute 'reset role';
  select count(*) into n from leads where id in (v_l1,v_l2,v_l3) and assigned_to is null;
  res := res || E'\n' || case when (j->>'changed')::boolean and (j->>'active')::boolean and n=3
                         then 'ok   A1 reactivated; the 3 leads were not handed back' else 'FAIL A1 '||j::text||' n='||n end;

  -- ===== distribution at the end of a deactivation (only when the distribution migration is present) =====
  if has_dist then
    update settings set auto_assign_leads = true where org_id = v_org;   -- OFF -> ON also distributes the waiting leads to A and B
    select count(*) into n from leads where id in (v_l1,v_l2,v_l3) and assigned_to is not null;
    res := res || E'\n' || case when n=3 then 'ok   X0 switching ON distributed the 3 waiting leads' else 'FAIL X0 assigned='||n end;
    -- now deactivate B: B's leads go to the pool and are spread over A immediately, in the same call
    execute 'set local role service_role';
    j := set_sales_person_active(v_m, v_b, false);
    execute 'reset role';
    select count(*) into n from leads where org_id=v_org and assigned_to=v_b and status not in ('won','lost');
    res := res || E'\n' || case when (j->>'leads_waiting')::int = 0 and n=0
                                  and (select count(*) from leads where org_id=v_org and assigned_to=v_a and status not in ('won','lost')) >= 1
                           then 'ok   X1 switch ON: flagged leads were spread over the remaining eligible person in the same call' else 'FAIL X1 '||j::text end;
    -- nobody eligible: deactivate A too -> leads wait, flagged
    execute 'set local role service_role';
    j := set_sales_person_active(v_m, v_a, false);
    execute 'reset role';
    res := res || E'\n' || case when (j->>'leads_waiting')::int >= 1
                           and (select count(*) from leads where org_id=v_org and auto_assign_pending and assigned_to is null) = (j->>'leads_waiting')::int
                           then 'ok   X2 nobody eligible: the leads wait, flagged ('||(j->>'leads_waiting')||')' else 'FAIL X2 '||j::text end;
  else
    res := res || E'\nINFO X distribution function not present in this run (run again with held/20261010120000 in front)';
  end if;

  raise exception E'RESULTS:%', res;
end
$t$;
