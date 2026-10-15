-- Rolled-back DB tests for 20261101100000_task_status_guard (P1a).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisations only.
-- Independent of P1b: every technician below is ACTIVE, so the result is the same with either definition of current_technician_id().
-- R1-R6 are the regression for why aa_guard_task_assignee_update was dropped (20261006200000): non-ops assignees must still be
-- able to edit, reassign and roll the due date, and any staff/technician must still be able to create a task for someone else.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_tech boolean default false) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  if p_tech then insert into public.technicians (org_id, profile_id, is_active) values (p_org, v, true); end if;
  return v;
end $f$;
-- run one statement as a user; 'ok:<rows>' or 'err:<message>'. 'set local role' only, always reset afterwards.
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
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
  v_org uuid; m uuid; o uuid; s uuid; t1 uuid; t2 uuid; c uuid;
  v_sup uuid; v_po uuid; v_t uuid; v_tpo uuid; x text; v_status text; v_po2 uuid; v_tpo2 uuid;
begin
  insert into public.organizations(name) values ('__TEST_task_guard') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org); s := pg_temp.mkuser('sales_admin', v_org);
  t1 := pg_temp.mkuser('technician', v_org, true); t2 := pg_temp.mkuser('technician', v_org, true);
  c := pg_temp.mkuser('customer', v_org);

  -- G: privileges and shape
  perform pg_temp.chk('G1 the guard function is not callable by anon / authenticated / PUBLIC',
    not has_function_privilege('anon', 'public.guard_task_status_change()', 'execute')
    and not has_function_privilege('authenticated', 'public.guard_task_status_change()', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'guard_task_status_change' and a.grantee = 0));
  perform pg_temp.chk('G2 the trigger exists on tasks, BEFORE INSERT OR UPDATE, row level',
    exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.tasks'::regclass and tg.tgname = 'aa_guard_task_status_change'
              and not tg.tgisinternal and (tg.tgtype & 2) = 2 and (tg.tgtype & 4) = 4 and (tg.tgtype & 16) = 16 and (tg.tgtype & 1) = 1));
  perform pg_temp.chk('G3 the old column guard is still gone',
    not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.tasks'::regclass and tg.tgname = 'aa_guard_task_assignee_update'));
  perform pg_temp.chk('G4 fixed search_path on the guard',
    (select coalesce(p.proconfig::text like '%search_path=%', false) from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = 'guard_task_status_change'));

  insert into public.tasks(org_id, assignee_id, title) values (v_org, t1, '__TEST_t1 task') returning id into v_t;

  -- A: completion
  x := pg_temp.act(t1, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A1 assignee can complete', x = 'ok:1', x);
  update public.tasks set status = 'open' where id = v_t;
  x := pg_temp.act(t2, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A2 another technician is blocked', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(s, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A3 sales_admin is blocked', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(o, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A4 operation_admin is blocked from completing on behalf', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(m, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A5 master is blocked from completing on behalf', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(t2, format('update public.tasks set assignee_id=%L, status=''done'' where id=%L', t2, v_t));
  perform pg_temp.chk('A6 reassign-to-self and complete in one statement is blocked (OLD.assignee_id is tested)',
    x like 'err:tasks: only the assignee%', x);
  select status::text into v_status from public.tasks where id = v_t;
  perform pg_temp.chk('A6b the task was not changed by the refused statement', v_status = 'open', v_status);
  x := pg_temp.act(c, format('update public.tasks set status=''done'' where id=%L', v_t));
  perform pg_temp.chk('A7 a customer cannot update a task at all', x = 'ok:0' or x like 'err:%', x);
  insert into public.tasks(org_id, assignee_id, title) values (v_org, null, '__TEST_unassigned') returning id into v_tpo;
  x := pg_temp.act(m, format('update public.tasks set status=''done'' where id=%L', v_tpo));
  perform pg_temp.chk('A8 an unassigned task cannot be completed by anyone through the API', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(m, format('update public.tasks set assignee_id=%L where id=%L', m, v_tpo));
  perform pg_temp.chk('A8b ...but any staff member can reassign it (the smallest fix: adopt, then complete)', x = 'ok:1', x);
  x := pg_temp.act(m, format('update public.tasks set status=''done'' where id=%L', v_tpo));
  perform pg_temp.chk('A8c ...after which the new assignee can complete it', x = 'ok:1', x);
  x := pg_temp.act(s, format('insert into public.tasks(org_id,assignee_id,title,status) values (%L,%L,''__TEST_ins'',''done'')', v_org, t1));
  perform pg_temp.chk('A9 inserting an already-done task for someone else is blocked', x like 'err:tasks: only the assignee%', x);
  x := pg_temp.act(s, format('insert into public.tasks(org_id,assignee_id,title,status) values (%L,%L,''__TEST_ins2'',''done'')', v_org, s));
  perform pg_temp.chk('A9b ...but one for yourself is allowed', x = 'ok:1', x);

  -- B: reopen
  update public.tasks set status = 'done' where id = v_t;
  x := pg_temp.act(s, format('update public.tasks set status=''open'' where id=%L', v_t));
  perform pg_temp.chk('B1 a non-assignee, non-ops user cannot reopen', x like 'err:tasks: only the assignee or operations%', x);
  x := pg_temp.act(o, format('update public.tasks set status=''open'' where id=%L', v_t));
  perform pg_temp.chk('B2 operation_admin can reopen', x = 'ok:1', x);
  update public.tasks set status = 'done' where id = v_t;
  x := pg_temp.act(t1, format('update public.tasks set status=''open'' where id=%L', v_t));
  perform pg_temp.chk('B3 the assignee can reopen', x = 'ok:1', x);
  x := pg_temp.act(t2, format('update public.tasks set status=''rolled'' where id=%L', v_t));
  perform pg_temp.chk('B4 open -> rolled is not a completion and is not restricted', x = 'ok:1', x);

  -- R: regression for the dropped column guard: only status is restricted
  update public.tasks set status = 'open', assignee_id = t1 where id = v_t;
  x := pg_temp.act(t1, format('update public.tasks set title=''__TEST_edited'', priority=''urgent'', description=''d'' where id=%L', v_t));
  perform pg_temp.chk('R1 a non-ops assignee can still edit title / priority / description', x = 'ok:1', x);
  x := pg_temp.act(t1, format('update public.tasks set assignee_id=%L where id=%L', t2, v_t));
  perform pg_temp.chk('R2 a non-ops assignee can still reassign', x = 'ok:1', x);
  x := pg_temp.act(s, format('update public.tasks set assignee_id=%L, due_date=current_date+3 where id=%L', t1, v_t));
  perform pg_temp.chk('R3 a non-assignee staff member can still reassign and change the due date', x = 'ok:1', x);
  x := pg_temp.act(t1, format('update public.tasks set due_date=current_date, original_due_date=current_date-2, rolled_count=rolled_count+1 where id=%L', v_t));
  perform pg_temp.chk('R4 the rollover columns are still writable', x = 'ok:1', x);
  x := pg_temp.act(t2, format('insert into public.tasks(org_id,assignee_id,assigned_by,title) values (%L,%L,%L,''__TEST_new'')', v_org, s, t2));
  perform pg_temp.chk('R5 a technician can still create a task for a staff member', x = 'ok:1', x);
  x := pg_temp.act(t2, format('delete from public.tasks where id=%L', v_t));
  perform pg_temp.chk('R6 delete is still ops-only', x = 'ok:0' or x like 'err:%', x);

  -- P: purchase-order task
  insert into public.suppliers(org_id, name) values (v_org, '__TEST_sup') returning id into v_sup;
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'sent') returning id into v_po;
  insert into public.tasks(org_id, assignee_id, title, ref_type, ref_id) values (v_org, o, '__TEST_po pay', 'purchase_order', v_po) returning id into v_tpo;
  x := pg_temp.act(o, format('update public.tasks set status=''done'' where id=%L', v_tpo));
  perform pg_temp.chk('P1 a non-master assignee cannot complete a purchase-order task', x like 'err:tasks: only a user who may approve%', x);
  select status::text into v_status from public.purchase_orders where id = v_po;
  perform pg_temp.chk('P2 the purchase order is still sent', v_status = 'sent', v_status);
  update public.tasks set assignee_id = m where id = v_tpo;
  x := pg_temp.act(m, format('update public.tasks set status=''done'' where id=%L', v_tpo));
  perform pg_temp.chk('P3 the master assignee completes it', x = 'ok:1', x);
  select status::text into v_status from public.purchase_orders where id = v_po;
  perform pg_temp.chk('P4 the existing trigger marked the purchase order paid', v_status = 'paid', v_status);
  x := pg_temp.act(s, format('insert into public.tasks(org_id,assignee_id,title,status,ref_type,ref_id) values (%L,%L,''__TEST_po ins'',''done'',''purchase_order'',%L)', v_org, s, v_po));
  perform pg_temp.chk('P5 a non-master cannot insert an already-done purchase-order task for themselves', x like 'err:tasks: only a user who may approve%', x);

  -- P6: escalation closed. tasks_update_assign RLS lets any staff/technician write ref_type/ref_id on any task, so a
  -- non-master assignee could otherwise set ref_type -> 'purchase_order' (from null) and status -> 'done' in the
  -- SAME statement: OLD.ref_type wasn't 'purchase_order', so a guard that tested only OLD.ref_type would miss it.
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'sent') returning id into v_po2;
  insert into public.tasks(org_id, assignee_id, title) values (v_org, t1, '__TEST_escalation') returning id into v_tpo2;
  x := pg_temp.act(t1, format('update public.tasks set ref_type=''purchase_order'', ref_id=%L, status=''done'' where id=%L', v_po2, v_tpo2));
  perform pg_temp.chk('P6 a non-master assignee cannot escalate ref_type to purchase_order while completing',
    x like 'err:tasks: only a user who may approve%', x);
  select status::text into v_status from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('P6b the purchase order the escalation targeted is untouched', v_status = 'sent', v_status);

  -- H: the PO-paid trigger's own hardening (defense in depth — this must hold even if the guard above did not).
  -- The guard above requires 'authenticated'/'anon' to apply at all, so these cases run as the migration/superuser
  -- role (always exempt from the column guard) and vary only auth.uid() via request.jwt.claims, to isolate
  -- _po_task_completed_marks_paid's own check from guard_task_status_change's.
  perform set_config('request.jwt.claims', '', true);  -- H1: no signed-in user at all (a true system job)
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'sent') returning id into v_po2;
  insert into public.tasks(org_id, assignee_id, title, ref_type, ref_id) values (v_org, o, '__TEST_h1', 'purchase_order', v_po2) returning id into v_tpo2;
  update public.tasks set status = 'done' where id = v_tpo2;
  select status::text into v_status from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('H1 no signed-in user (system job): the purchase order IS marked paid', v_status = 'paid', v_status);

  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);  -- H2: signed-in, non-master
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'sent') returning id into v_po2;
  insert into public.tasks(org_id, assignee_id, title, ref_type, ref_id) values (v_org, o, '__TEST_h2', 'purchase_order', v_po2) returning id into v_tpo2;
  update public.tasks set status = 'done' where id = v_tpo2;  -- current_user is still not 'authenticated' here: the column guard is exempt either way
  select status::text into v_status from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('H2 a signed-in NON-master (auth.uid() = operation_admin): the purchase order is NOT marked paid', v_status = 'sent', v_status);
  select status::text into v_status from public.tasks where id = v_tpo2;
  perform pg_temp.chk('H2b ...the task itself still goes to done (the trigger only skips the PO side-effect)', v_status = 'done', v_status);

  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);  -- H3: signed-in master
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'sent') returning id into v_po2;
  insert into public.tasks(org_id, assignee_id, title, ref_type, ref_id) values (v_org, m, '__TEST_h3', 'purchase_order', v_po2) returning id into v_tpo2;
  update public.tasks set status = 'done' where id = v_tpo2;
  select status::text into v_status from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('H3 a signed-in master: the purchase order IS marked paid', v_status = 'paid', v_status);
  perform pg_temp.chk('H4 the trigger function itself is not callable by anon / authenticated / PUBLIC',
    not has_function_privilege('anon', 'public._po_task_completed_marks_paid()', 'execute')
    and not has_function_privilege('authenticated', 'public._po_task_completed_marks_paid()', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and p.proname = '_po_task_completed_marks_paid' and a.grantee = 0));
  perform set_config('request.jwt.claims', '', true);

  -- S: exempt paths
  insert into public.purchase_orders(org_id, supplier_id, status) values (v_org, v_sup, 'received') returning id into v_po;
  insert into public.tasks(org_id, assignee_id, title, ref_type, ref_id) values (v_org, o, '__TEST_po pay 2', 'purchase_order', v_po) returning id into v_tpo;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.mark_po_paid(v_po);
    execute 'reset role';
    select status::text into v_status from public.tasks where id = v_tpo;
    perform pg_temp.chk('S1 mark_po_paid still closes the reminder task assigned to someone else (definer is exempt)', v_status = 'done', v_status);
  exception when others then
    execute 'reset role';
    perform pg_temp.chk('S1 mark_po_paid still closes the reminder task', false, sqlerrm);
  end;
  update public.tasks set status = 'open' where id = v_tpo;
  begin
    update public.tasks set status = 'done' where id = v_tpo;
    perform pg_temp.chk('S2 a non-authenticated role (service role / migration) is exempt', true);
  exception when others then
    perform pg_temp.chk('S2 a non-authenticated role is exempt', false, sqlerrm);
  end;
  -- advance_recurring_tasks inserts open successors as the function owner and never touches status
  insert into public.tasks(org_id, assignee_id, title, due_date, is_recurring) values (v_org, t1, '__TEST_recurring', current_date - 1, true);
  perform public.advance_recurring_tasks(v_org);
  perform pg_temp.chk('S3 advance_recurring_tasks still creates the open successor under the guard',
    (select count(*) from public.tasks where org_id = v_org and ref_type = 'recurring_task_series' and status = 'open') = 1);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
