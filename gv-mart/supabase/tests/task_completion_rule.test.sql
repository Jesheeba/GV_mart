-- Rolled-back test for migrations/20261025100000_task_completion_rule.sql
-- (runner: migration file, THEN this block, as two separate statements in one rolled-back transaction;
--  never concatenate them into one file. This block always ends in RAISE 'RESULTS', so nothing persists.)
-- Includes the regression for why aa_guard_task_assignee_update was dropped in 20261006200000:
-- a non-ops assignee must still be able to edit, reassign and roll the due date of tasks, and any
-- staff/technician must still be able to create a task for someone else.
create or replace function pg_temp.act(p_uid uuid, p_sql text) returns text
language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;

do $t$
declare
  res text := ''; v_org uuid; r record; v_ids jsonb := '{}'::jsonb; v_u uuid;
  v_sup uuid; v_po uuid; v_t uuid; v_tpo uuid; x text; v_status text;
  m uuid; o uuid; s uuid; t1 uuid; t2 uuid; ti uuid; c uuid;
begin
  insert into organizations(name) values ('__TEST_task_rule') returning id into v_org;
  for r in select * from (values
      ('master','master',true,false),('ops','operation_admin',true,false),('sales','sales_admin',true,false),
      ('tech1','technician',true,true),('tech2','technician',true,true),('techinactive','technician',true,false),
      ('customer','customer',true,false)) t(n,ro,ac,tech)
  loop
    v_u := gen_random_uuid(); v_ids := v_ids || jsonb_build_object(r.n, v_u);
    insert into auth.users(id,email) values (v_u,'__test_'||v_u||'@example.invalid');
    insert into profiles(id,org_id,full_name,role,is_active) values (v_u,v_org,'__TEST_'||r.n,r.ro::user_role,r.ac);
    if r.ro = 'technician' then insert into technicians(org_id,profile_id,is_active) values (v_org,v_u,r.tech); end if;
  end loop;
  m := (v_ids->>'master')::uuid; o := (v_ids->>'ops')::uuid; s := (v_ids->>'sales')::uuid;
  t1 := (v_ids->>'tech1')::uuid; t2 := (v_ids->>'tech2')::uuid; ti := (v_ids->>'techinactive')::uuid; c := (v_ids->>'customer')::uuid;

  -- C1/C2: helper reflects is_active
  perform set_config('request.jwt.claims', json_build_object('sub', t1, 'role','authenticated')::text, true);
  res := res || E'\n' || case when public.current_technician_id() is not null then 'ok   C1 active technician resolves' else 'FAIL C1' end;
  perform set_config('request.jwt.claims', json_build_object('sub', ti, 'role','authenticated')::text, true);
  res := res || E'\n' || case when public.current_technician_id() is null then 'ok   C2 inactive technician resolves to null' else 'FAIL C2' end;

  -- fixture task (superuser insert: guard exempt)
  insert into tasks(org_id,assignee_id,title) values (v_org,t1,'__TEST_t1 task') returning id into v_t;

  -- A: completion
  x := pg_temp.act(t1, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   A1 assignee can complete' else 'FAIL A1 '||x end;
  update tasks set status='open' where id=v_t;
  x := pg_temp.act(t2, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A2 other technician blocked' else 'FAIL A2 '||x end;
  x := pg_temp.act(s, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A3 sales_admin blocked' else 'FAIL A3 '||x end;
  x := pg_temp.act(o, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A4 operation_admin blocked' else 'FAIL A4 '||x end;
  x := pg_temp.act(m, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A5 master blocked' else 'FAIL A5 '||x end;
  -- reassign + complete in ONE statement by a non-assignee is still blocked (OLD.assignee_id is tested)
  x := pg_temp.act(t2, format('update tasks set assignee_id=%L, status=''done'' where id=%L', t2, v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A6 reassign-and-complete blocked' else 'FAIL A6 '||x end;
  x := pg_temp.act(c, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x='ok:0' or x like 'err:%' then 'ok   A7 customer cannot update ('||x||')' else 'FAIL A7 '||x end;
  insert into tasks(org_id,assignee_id,title) values (v_org,null,'__TEST_unassigned') returning id into v_tpo;
  x := pg_temp.act(m, format('update tasks set status=''done'' where id=%L', v_tpo));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A8 unassigned task blocked' else 'FAIL A8 '||x end;
  x := pg_temp.act(s, format('insert into tasks(org_id,assignee_id,title,status) values (%L,%L,''__TEST_ins'',''done'')', v_org, t1));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee%' then 'ok   A9 insert-as-done for another blocked' else 'FAIL A9 '||x end;

  -- B: reopen
  update tasks set status='done' where id=v_t;
  x := pg_temp.act(s, format('update tasks set status=''open'' where id=%L', v_t));
  res := res || E'\n' || case when x like 'err:tasks: only the assignee or operations%' then 'ok   B1 sales cannot reopen' else 'FAIL B1 '||x end;
  x := pg_temp.act(o, format('update tasks set status=''open'' where id=%L', v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   B2 ops can reopen' else 'FAIL B2 '||x end;

  -- R: REGRESSION for the dropped column guard: nothing but status is restricted
  update tasks set status='open', assignee_id=t1 where id=v_t;
  x := pg_temp.act(t1, format('update tasks set title=''__TEST_edited'', priority=''urgent'', description=''d'' where id=%L', v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   R1 non-ops assignee can still edit title/priority' else 'FAIL R1 '||x end;
  x := pg_temp.act(t1, format('update tasks set assignee_id=%L where id=%L', t2, v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   R2 non-ops assignee can still reassign' else 'FAIL R2 '||x end;
  x := pg_temp.act(s, format('update tasks set assignee_id=%L, due_date=current_date+3 where id=%L', t1, v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   R3 non-assignee staff can still reassign and change due date' else 'FAIL R3 '||x end;
  x := pg_temp.act(t1, format('update tasks set due_date=current_date, original_due_date=current_date-2, rolled_count=rolled_count+1 where id=%L', v_t));
  res := res || E'\n' || case when x='ok:1' then 'ok   R4 rollover columns still writable' else 'FAIL R4 '||x end;
  x := pg_temp.act(t2, format('insert into tasks(org_id,assignee_id,assigned_by,title) values (%L,%L,%L,''__TEST_new'')', v_org, s, t2));
  res := res || E'\n' || case when x='ok:1' then 'ok   R5 technician can still create a task for staff' else 'FAIL R5 '||x end;
  x := pg_temp.act(t2, format('delete from tasks where id=%L', v_t));
  res := res || E'\n' || case when x='ok:0' or x like 'err:%' then 'ok   R6 delete still ops-only ('||x||')' else 'FAIL R6 '||x end;

  -- P: purchase-order task
  insert into suppliers(org_id,name) values (v_org,'__TEST_sup') returning id into v_sup;
  insert into purchase_orders(org_id,supplier_id,status) values (v_org,v_sup,'sent') returning id into v_po;
  insert into tasks(org_id,assignee_id,title,ref_type,ref_id) values (v_org,o,'__TEST_po pay','purchase_order',v_po) returning id into v_tpo;
  x := pg_temp.act(o, format('update tasks set status=''done'' where id=%L', v_tpo));
  res := res || E'\n' || case when x like 'err:tasks: only a user who may approve%' then 'ok   P1 non-master assignee cannot complete PO task' else 'FAIL P1 '||x end;
  select status::text into v_status from purchase_orders where id=v_po;
  res := res || E'\n' || case when v_status='sent' then 'ok   P2 PO still sent' else 'FAIL P2 '||v_status end;
  update tasks set assignee_id=m where id=v_tpo;
  x := pg_temp.act(m, format('update tasks set status=''done'' where id=%L', v_tpo));
  res := res || E'\n' || case when x='ok:1' then 'ok   P3 master assignee completes PO task' else 'FAIL P3 '||x end;
  select status::text into v_status from purchase_orders where id=v_po;
  res := res || E'\n' || case when v_status='paid' then 'ok   P4 trigger marked PO paid' else 'FAIL P4 '||v_status end;

  -- S: exempt paths. mark_po_paid completes the reminder task assigned to someone else.
  insert into purchase_orders(org_id,supplier_id,status) values (v_org,v_sup,'received') returning id into v_po;
  insert into tasks(org_id,assignee_id,title,ref_type,ref_id) values (v_org,o,'__TEST_po pay 2','purchase_order',v_po) returning id into v_tpo;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.mark_po_paid(v_po);
    execute 'reset role';
    select status::text into v_status from tasks where id=v_tpo;
    res := res || E'\n' || case when v_status='done' then 'ok   S1 mark_po_paid still closes the task (definer exempt)' else 'FAIL S1 '||v_status end;
  exception when others then
    execute 'reset role';
    res := res || E'\nFAIL S1 '||sqlerrm;
  end;
  update tasks set status='open' where id=v_tpo;
  begin
    update tasks set status='done' where id=v_tpo;
    res := res || E'\nok   S2 non-authenticated role exempt';
  exception when others then
    res := res || E'\nFAIL S2 '||sqlerrm;
  end;

  -- I: deactivated technician loses task access
  insert into tasks(org_id,assignee_id,title) values (v_org,ti,'__TEST_inactive') returning id into v_t;
  x := pg_temp.act(ti, 'select 1 from tasks');
  res := res || E'\n' || case when x='ok:0' then 'ok   I1 inactive technician sees no tasks' else 'FAIL I1 '||x end;
  x := pg_temp.act(ti, format('update tasks set status=''done'' where id=%L', v_t));
  res := res || E'\n' || case when x='ok:0' or x like 'err:%' then 'ok   I2 inactive technician cannot update ('||x||')' else 'FAIL I2 '||x end;
  x := pg_temp.act(t1, 'select 1 from tasks');
  res := res || E'\n' || case when x like 'ok:%' and substr(x,4)::int > 0 then 'ok   I3 active technician still sees tasks' else 'FAIL I3 '||x end;

  raise exception E'RESULTS:%', res;
end
$t$;
