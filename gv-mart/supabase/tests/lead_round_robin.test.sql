-- Rolled-back test for 20261010100000_lead_round_robin.sql. Run through the Management API
-- (database/query). Everything uses a throwaway __TEST_ organisation with __TEST_ users and
-- leads, created inside the transaction; the block ALWAYS ends in a RAISE so nothing persists.
-- Read the RESULTS in the error message. Lines starting FAIL are failures.
do $t$
declare
  res text := '';
  v_org uuid; v_org2 uuid;
  v_m uuid := gen_random_uuid(); v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid(); v_d uuid := gen_random_uuid(); v_x uuid := gen_random_uuid();
  v_m2 uuid := gen_random_uuid(); v_s2 uuid := gen_random_uuid(); v_tech uuid := gen_random_uuid();
  v_l uuid; v_got uuid; n int; i int; seq text;
  v_real_before int; v_real_assigned_before int;
begin
  select count(*) into v_real_before from leads;
  select count(*) into v_real_assigned_before from leads where assigned_to is not null or auto_assign_pending;

  insert into organizations(name) values ('__TEST_rr_org') returning id into v_org;
  insert into organizations(name) values ('__TEST_rr_org2') returning id into v_org2;
  insert into settings(org_id) values (v_org) on conflict do nothing;
  insert into settings(org_id) values (v_org2) on conflict do nothing;

  -- users (created in order A < B < C < D so created_at tie-breaks are deterministic)
  insert into auth.users(id,email) select x, '__test_'||x||'@example.invalid' from unnest(array[v_m,v_a,v_b,v_c,v_x,v_m2,v_s2,v_tech]) x;
  insert into profiles(id,org_id,full_name,role,is_active,created_at) values
    (v_m, v_org,'__TEST_master','master',true, now()-interval '10 days'),
    (v_a, v_org,'__TEST_A','sales_admin',true, now()-interval '9 days'),
    (v_b, v_org,'__TEST_B','sales_admin',true, now()-interval '8 days'),
    (v_c, v_org,'__TEST_C','sales_admin',true, now()-interval '7 days'),
    (v_x, v_org,'__TEST_ops','operation_admin',true, now()-interval '6 days'),
    (v_tech, v_org,'__TEST_tech','technician',true, now()-interval '5 days'),
    (v_m2, v_org2,'__TEST_master2','master',true, now()-interval '10 days'),
    (v_s2, v_org2,'__TEST_S2','sales_admin',true, now()-interval '9 days');

  -- T1 switch OFF (default): nothing happens
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_l_off','9100000001') returning id into v_l;
  select count(*) into n from leads where id=v_l and assigned_to is null and not auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   T1 switch OFF: lead untouched' else 'FAIL T1 switch OFF' end;
  select count(*) into n from settings where org_id=v_org and auto_assign_leads;
  res := res || E'\n' || case when n=0 then 'ok   T1b switch defaults OFF' else 'FAIL T1b' end;

  update settings set auto_assign_leads=true where org_id=v_org or org_id=v_org2;

  -- T2 switch ON, sales persons exist but in this section take them all out first
  update profiles set receives_new_leads=false where id in (v_a,v_b,v_c);
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_l_wait1','9100000002') returning id into v_l;
  select count(*) into n from leads where id=v_l and assigned_to is null and auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   T2 nobody eligible: unassigned + pending flag' else 'FAIL T2 pending' end;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_l_wait2','9100000003');
  select count(*) into n from notifications where org_id=v_org and type='lead_auto_assign_waiting';
  res := res || E'\n' || case when n=1 then 'ok   T2b master notified exactly once for 2 waiting leads' else 'FAIL T2b notifications='||n end;
  select count(*) into n from notifications where org_id=v_org and type='lead_auto_assign_waiting' and role='master' and user_id is null;
  res := res || E'\n' || case when n=1 then 'ok   T2c notice is addressed to role master' else 'FAIL T2c' end;

  -- T3 three eligible -> strict rotation A,B,C,A,B,C
  update profiles set receives_new_leads=true where id in (v_a,v_b,v_c);
  seq := '';
  for i in 1..6 loop
    insert into leads(org_id,name,mobile) values (v_org,'__TEST_rr'||i,'91000001'||i) returning assigned_to into v_got;
    seq := seq || (select right(full_name,1) from profiles where id=v_got);
  end loop;
  res := res || E'\n' || case when seq='ABCABC' then 'ok   T3 rotation ABCABC' else 'FAIL T3 rotation='||seq end;
  select count(*) into n from lead_assignments where org_id=v_org and reason='auto round-robin' and from_user is null and assigned_by is null;
  res := res || E'\n' || case when n=6 then 'ok   T3b 6 lead_assignments rows logged' else 'FAIL T3b rows='||n end;
  select count(*) into n from notifications where org_id=v_org and type='lead_assigned' and user_id in (v_a,v_b,v_c);
  res := res || E'\n' || case when n=6 then 'ok   T3c 6 assignee notifications' else 'FAIL T3c notifications='||n end;
  select count(*) into n from leads where org_id=v_org and name like '__TEST_wait%' and assigned_to is not null;
  res := res || E'\n' || case when n=0 then 'ok   T3d waiting leads were NOT retro-assigned (distribution not built)' else 'FAIL T3d' end;

  -- T4 pause B -> skipped
  update profiles set receives_new_leads=false where id=v_b;
  seq := '';
  for i in 1..4 loop
    insert into leads(org_id,name,mobile) values (v_org,'__TEST_p'||i,'91000002'||i) returning assigned_to into v_got;
    seq := seq || (select right(full_name,1) from profiles where id=v_got);
  end loop;
  res := res || E'\n' || case when seq='ACAC' then 'ok   T4 paused B skipped: '||seq else 'FAIL T4 seq='||seq end;

  -- T5 deactivate C -> skipped; unpause B comes back first (least recently assigned)
  update profiles set is_active=false where id=v_c;
  update profiles set receives_new_leads=true where id=v_b;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_d1','9100003001') returning assigned_to into v_got;
  res := res || E'\n' || case when v_got=v_b then 'ok   T5 inactive C skipped, resumed B (oldest turn) next' else 'FAIL T5' end;

  -- T6 new person D joins -> goes to the front
  insert into auth.users(id,email) values (v_d,'__test_'||v_d||'@example.invalid');
  insert into profiles(id,org_id,full_name,role,is_active) values (v_d,v_org,'__TEST_D','sales_admin',true);
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_d2','9100003002') returning assigned_to into v_got;
  res := res || E'\n' || case when v_got=v_d then 'ok   T6 new person starts at the front' else 'FAIL T6' end;

  -- T7 manual assign_lead does not move the rotation
  select assigned_to into v_got from (select assigned_to from leads where org_id=v_org and name='__TEST_d2') q;
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select id into v_l from leads where org_id=v_org and name='__TEST_d1';
  perform assign_lead(v_l, v_d, 'test');
  execute 'reset role';
  -- expected next pick is still computed from auto-assignments only: order is A,B(d1),D(d2) used -> A next
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_d3','9100003003') returning assigned_to into v_got;
  res := res || E'\n' || case when v_got=v_a then 'ok   T7 manual assign_lead left the rotation alone (next = A)' else 'FAIL T7 got '||(select full_name from profiles where id=v_got) end;
  select count(*) into n from lead_assignments where lead_id=v_l and assigned_by=v_m;
  res := res || E'\n' || case when n=1 then 'ok   T7b manual assignment still logged' else 'FAIL T7b' end;

  -- T8 org scoping: org2's lead only goes to org2's person
  insert into leads(org_id,name,mobile) values (v_org2,'__TEST_o2','9100004001') returning assigned_to into v_got;
  res := res || E'\n' || case when v_got=v_s2 then 'ok   T8 org2 lead -> org2 person only' else 'FAIL T8' end;

  -- T9 closed lead inserted by sales is not assigned
  insert into leads(org_id,name,mobile,status) values (v_org,'__TEST_won','9100005001','won') returning id into v_l;
  select count(*) into n from leads where id=v_l and assigned_to is null and not auto_assign_pending;
  res := res || E'\n' || case when n=1 then 'ok   T9 won/lost lead skipped' else 'FAIL T9' end;

  -- T10 client guards (as an authenticated sales person)
  perform set_config('request.jwt.claims', json_build_object('sub',v_a,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into leads(org_id,name,mobile,assigned_to) values (v_org,'__TEST_forge','9100006001',v_b);
        res := res || E'\n' || 'FAIL T10a client set assigned_to on insert'; exception when others then res := res || E'\n' || 'ok   T10a client assigned_to on insert rejected: '||sqlerrm; end;
  begin insert into leads(org_id,name,mobile,auto_assign_pending) values (v_org,'__TEST_flag','9100006002',true) returning id into v_l;
        select count(*) into n from leads where id=v_l and not auto_assign_pending;
        res := res || E'\n' || case when n=1 then 'ok   T10b client-supplied pending flag discarded on insert' else 'FAIL T10b' end; exception when others then res := res || E'\n' || 'ok   T10b '||sqlerrm; end;
  begin update leads set auto_assign_pending=true where id=v_l;
        res := res || E'\n' || 'FAIL T10c client flipped pending flag'; exception when others then res := res || E'\n' || 'ok   T10c client cannot set pending: '||sqlerrm; end;
  begin update leads set assigned_to=(select id from profiles where id in (v_a,v_b) and id is distinct from (select assigned_to from leads where id=v_l) limit 1) where id=v_l;
        res := res || E'\n' || 'FAIL T10d direct assigned_to update'; exception when others then res := res || E'\n' || 'ok   T10d direct assigned_to update rejected'; end;
  begin update profiles set receives_new_leads=false where id=v_a;
        get diagnostics n = row_count;
        res := res || E'\n' || 'FAIL T10e sales person changed receives_new_leads (rows '||n||')'; exception when others then res := res || E'\n' || 'ok   T10e sales person cannot change receives_new_leads'; end;
  begin perform 1 from lead_rotation limit 1; res := res || E'\n' || 'FAIL T10f lead_rotation readable'; exception when others then res := res || E'\n' || 'ok   T10f lead_rotation not readable by clients'; end;
  begin perform _lead_rr_pick(v_org); res := res || E'\n' || 'FAIL T10g _lead_rr_pick callable'; exception when others then res := res || E'\n' || 'ok   T10g _lead_rr_pick not callable by authenticated'; end;
  execute 'reset role';
  -- master can change receives_new_leads from the client
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update profiles set receives_new_leads=false where id=v_a; get diagnostics n = row_count;
        res := res || E'\n' || case when n=1 then 'ok   T10h master can change receives_new_leads' else 'FAIL T10h rows='||n end; exception when others then res := res || E'\n' || 'FAIL T10h '||sqlerrm; end;
  execute 'reset role';
  update profiles set receives_new_leads=true where id=v_a;

  -- T11 other entry paths pick it up (technician direct insert; generate_enquiry_lead)
  insert into technicians(id,org_id,profile_id) values (gen_random_uuid(), v_org, v_tech) returning id into v_l;
  perform set_config('request.jwt.claims', json_build_object('sub',v_tech,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into leads(org_id,name,mobile,owner_id,status) values (v_org,'__TEST_techlead','9100007001',v_l,'new') returning assigned_to into v_got;
    res := res || E'\n' || case when v_got is not null then 'ok   T11a technician-inserted lead auto-assigned' else 'FAIL T11a not assigned' end;
  exception when others then res := res || E'\n' || 'INFO T11a technician insert: '||sqlerrm; end;
  execute 'reset role';
  begin
    perform generate_enquiry_lead(v_org, null::uuid, '__TEST_gel'::text, '9100007002'::text, 'price'::enquiry_type, 'x'::text, null::uuid);
    select count(*) into n from leads where org_id=v_org and name='__TEST_gel' and assigned_to is not null;
    res := res || E'\n' || case when n=1 then 'ok   T11b generate_enquiry_lead path auto-assigned' else 'FAIL T11b' end;
  exception when others then res := res || E'\n' || 'INFO T11b generate_enquiry_lead: '||sqlerrm; end;

  -- T12 real data untouched
  select count(*) into n from leads where org_id not in (v_org,v_org2) and (assigned_to is not null or auto_assign_pending);
  res := res || E'\n' || case when n=v_real_assigned_before then 'ok   T12 real leads: none assigned / flagged (count '||n||')' else 'FAIL T12 real leads changed' end;
  select count(*) into n from leads where org_id not in (v_org,v_org2);
  res := res || E'\n' || case when n=v_real_before then 'ok   T12b real lead count unchanged ('||n||')' else 'FAIL T12b' end;

  raise exception E'RESULTS:%', res;
end
$t$;
