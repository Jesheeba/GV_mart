-- Rolled-back test for 20261010120000_lead_distribute_pending.sql. To test BEFORE applying, the runner
-- concatenates the migration file in front of this block in one transaction (all rolled back by the RAISE).
do $t$
declare
  res text := ''; v_org uuid; v_org2 uuid; n int; seq text;
  v_m uuid := gen_random_uuid(); v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
  v_m2 uuid := gen_random_uuid(); v_s2 uuid := gen_random_uuid();
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; l_closed uuid; l_manual uuid; l_old uuid; l_o2 uuid;
  v_real_assigned int; v_real int;
begin
  select count(*) into v_real from leads; select count(*) into v_real_assigned from leads where assigned_to is not null or auto_assign_pending;
  insert into organizations(name) values ('__TEST_dp_org') returning id into v_org;
  insert into organizations(name) values ('__TEST_dp_org2') returning id into v_org2;
  insert into settings(org_id) values (v_org) on conflict do nothing;
  insert into settings(org_id) values (v_org2) on conflict do nothing;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_a,v_b,v_m2]) x;
  insert into profiles(id,org_id,full_name,role,is_active,receives_new_leads,created_at) values
    (v_m, v_org,'__TEST_master','master',true,true, now()-interval '10 days'),
    (v_a, v_org,'__TEST_A','sales_admin',true,false, now()-interval '9 days'),
    (v_b, v_org,'__TEST_B','sales_admin',true,false, now()-interval '8 days'),
    (v_m2,v_org2,'__TEST_master2','master',true,true, now()-interval '10 days');

  -- D5a switch OFF: leads are not flagged; person becoming eligible distributes nothing
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_unflagged','9400000001', now()-interval '5 days') returning id into l_old;
  update profiles set receives_new_leads=true where id=v_a;
  update profiles set receives_new_leads=false where id=v_a;
  select count(*) into n from leads where id=l_old and assigned_to is null and not auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   D5a switch OFF: nothing flagged, nothing distributed' else 'FAIL D5a' end;

  -- build waiting leads with switch ON and nobody eligible (distinct created_at, oldest first = w1)
  update settings set auto_assign_leads=true where org_id in (v_org,v_org2);
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_w1','9400000011', now()-interval '4 hours') returning id into l1;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_w2','9400000012', now()-interval '3 hours') returning id into l2;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_w3','9400000013', now()-interval '2 hours') returning id into l3;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_w4','9400000014', now()-interval '1 hours') returning id into l4;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_closed','9400000015', now()-interval '3 hours') returning id into l_closed;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_manual','9400000016', now()-interval '3 hours') returning id into l_manual;
  insert into leads(org_id,name,mobile,created_at) values (v_org2,'__TEST_o2wait','9400000017', now()-interval '3 hours') returning id into l_o2;
  select count(*) into n from leads where org_id in (v_org,v_org2) and auto_assign_pending;
  res := res || E'\n' || case when n=7 then 'ok   setup: 7 waiting leads flagged' else 'FAIL setup n='||n end;

  -- closed + manually assigned while waiting
  update leads set status='lost' where id=l_closed;
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform assign_lead(l_manual, v_m, 'manual while waiting');
  execute 'reset role';

  -- D1/D2 both A and B become eligible in ONE statement -> A,B,A,B oldest first
  update profiles set receives_new_leads=true where id in (v_a,v_b);
  select string_agg(right(p.full_name,1), '' order by l.created_at) into seq from leads l join profiles p on p.id=l.assigned_to where l.id in (l1,l2,l3,l4);
  res := res || E'\n' || case when seq='ABAB' then 'ok   D1/D2 waiting leads distributed oldest first and fairly: '||seq else 'FAIL D1 seq='||coalesce(seq,'null') end;
  select count(*) into n from lead_assignments where org_id=v_org and reason='auto round-robin (waiting lead)';
  res := res || E'\n' || case when n=4 then 'ok   D1b 4 assignment rows logged' else 'FAIL D1b n='||n end;
  select count(*) into n from notifications where org_id=v_org and type='lead_assigned' and user_id in (v_a,v_b);
  res := res || E'\n' || case when n=4 then 'ok   D1c 4 assignee notifications' else 'FAIL D1c n='||n end;
  select count(*) into n from leads where id in (l1,l2,l3,l4) and auto_assign_pending;
  res := res || E'\n' || case when n=0 then 'ok   D1d flags cleared' else 'FAIL D1d' end;

  -- D3 closed / manual: flag cleared, nothing else changed
  select count(*) into n from leads where id=l_closed and not auto_assign_pending and assigned_to is null and status='lost';
  res := res || E'\n' || case when n=1 then 'ok   D3a closed lead: flag cleared, unassigned, still lost' else 'FAIL D3a' end;
  select count(*) into n from leads where id=l_manual and not auto_assign_pending and assigned_to=v_m;
  res := res || E'\n' || case when n=1 then 'ok   D3b manually assigned lead: flag cleared, assignee unchanged' else 'FAIL D3b' end;
  select count(*) into n from lead_assignments where lead_id in (l_closed,l_manual) and reason like 'auto%';
  res := res || E'\n' || case when n=0 then 'ok   D3c no auto row for those two' else 'FAIL D3c' end;

  -- D4 unflagged lead untouched; D7 other org untouched
  select count(*) into n from leads where id=l_old and assigned_to is null and not auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   D4 unflagged unassigned lead never touched' else 'FAIL D4' end;
  select count(*) into n from leads where id=l_o2 and assigned_to is null and auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   D7 other organisation: its waiting lead untouched' else 'FAIL D7' end;

  -- D6 master notice
  select count(*) into n from notifications where org_id=v_org and type='lead_auto_assign_waiting' and not is_read;
  res := res || E'\n' || case when n=0 then 'ok   D6a master waiting notice marked read' else 'FAIL D6a unread='||n end;
  select count(*) into n from notifications where org_id=v_org2 and type='lead_auto_assign_waiting' and not is_read;
  res := res || E'\n' || case when n=1 then 'ok   D6b other org notice still unread' else 'FAIL D6b n='||n end;

  -- D5b switch OFF with waiting lead: eligible person appears -> nothing; then switch ON distributes
  update settings set auto_assign_leads=false where org_id=v_org2;
  insert into auth.users(id,email) values (v_s2,'__test_'||v_s2||'@example.invalid');
  insert into profiles(id,org_id,full_name,role,is_active) values (v_s2,v_org2,'__TEST_S2','sales_admin',true);
  select count(*) into n from leads where id=l_o2 and assigned_to is null and auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   D5b switch OFF: new eligible person -> waiting lead stays waiting' else 'FAIL D5b' end;
  update settings set auto_assign_leads=true where org_id=v_org2;
  select count(*) into n from leads where id=l_o2 and assigned_to=v_s2 and not auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   D5c switch OFF->ON distributes the waiting lead' else 'FAIL D5c' end;

  -- D8 privileges
  res := res || E'\n' || case when not has_function_privilege('authenticated','public._lead_distribute_pending(uuid)','execute') and not has_function_privilege('anon','public._lead_distribute_pending(uuid)','execute') then 'ok   D8 distribute fn not executable by anon/authenticated' else 'FAIL D8' end;

  -- D9 real data untouched
  select count(*) into n from leads where org_id not in (v_org,v_org2) and (assigned_to is not null or auto_assign_pending);
  res := res || E'\n' || case when n=v_real_assigned then 'ok   D9 real leads: none assigned/flagged ('||n||')' else 'FAIL D9' end;
  select count(*) into n from leads where org_id not in (v_org,v_org2);
  res := res || E'\n' || case when n=v_real then 'ok   D9b real lead count unchanged ('||n||')' else 'FAIL D9b' end;

  raise exception E'RESULTS:%', res;
end
$t$;
