-- DB tests for 20261101100000_task_completion_rule. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisation only.
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
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
create function pg_temp.mk(p_org uuid, p_assignee uuid, p_by uuid, p_ref text default null, p_ref_id uuid default null) returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, ref_type, ref_id, source) values (p_org, p_assignee, p_by, '__TEST_ task', p_ref, p_ref_id, 'assigned') returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_sales2 uuid; v_tp uuid; v_tp2 uuid; v_tech uuid; v_tech2 uuid; v_m2 uuid;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; t5 uuid; t6 uuid; t7 uuid; v_sup uuid; v_po uuid; v_po2 uuid;
  s text; n int; st text; x uuid; v_base text; v_now text;
begin
  insert into organizations (name) values ('__TEST_taskrule') returning id into v_org;
  insert into organizations (name) values ('__TEST_taskrule_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_sales2 := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;

  -- ---------- structure ----------
  perform pg_temp.chk('the 20261006190000 guard stays dropped; the new guard exists, fires before insert or update, and is not client-callable',
    to_regprocedure('public.guard_task_assignee_update()') is null
    and exists (select 1 from pg_trigger t where t.tgrelid = 'public.tasks'::regclass and t.tgname = 'aa_guard_task_completion' and not t.tgisinternal and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4 and (t.tgtype & 16) = 16)
    and not has_function_privilege('authenticated', 'public.guard_task_completion()', 'execute')
    and not has_function_privilege('anon', 'public.guard_task_completion()', 'execute'));

  -- ---------- the assignee finishes; edits and reassigns still work (the reason the old guard was dropped) ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set title = 'edited', description = 'd', priority = 'urgent', due_date = current_date + 3 where id = %L$q$, t1));
  perform pg_temp.chk('REGRESSION: a non-ops assignee can still edit title, description, priority and due date of their task', s is null, coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update tasks set assignee_id = %L, assigned_by = %L where id = %L$q$, v_tp2, v_tp, t1));
  perform pg_temp.chk('REGRESSION: a non-ops assignee can still hand the task on (reassign)', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_pg();
  t1 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t1));
  perform pg_temp.as_pg();
  perform pg_temp.chk('the assignee can mark their own task finished', s is null and (select status::text from tasks where id = t1) = 'done', coalesce(s, 'ok'));

  -- ---------- nobody else can finish it ----------
  t2 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t2));
  perform pg_temp.chk('operation_admin cannot finish a task assigned to someone else', s like '%only the person a task is assigned to%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t2));
  perform pg_temp.chk('master cannot finish it on the assignee''s behalf', s like '%only the person a task is assigned to%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t2));
  perform pg_temp.chk('the assigner cannot finish it either', s like '%only the person a task is assigned to%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp2);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t2));
  perform pg_temp.as_pg();
  perform pg_temp.chk('an unrelated technician cannot finish it (and cannot even update it)',
    (select status::text from tasks where id = t2) = 'open', coalesce(s, 'filtered'));

  -- ---------- reassign by operations, then the new assignee finishes ----------
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set assignee_id = %L, assigned_by = %L where id = %L$q$, v_sales2, v_ops, t2));
  perform pg_temp.chk('operations can reassign a task they do not own', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales2);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t2));
  perform pg_temp.as_pg();
  perform pg_temp.chk('the new assignee can finish it', s is null and (select status::text from tasks where id = t2) = 'done', coalesce(s, 'ok'));

  -- ---------- the assigner may edit and reassign, an unrelated staff member may not touch it ----------
  t3 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set title = 'by assigner', assignee_id = %L where id = %L$q$, v_tp2, t3));
  perform pg_temp.chk('the assigner can edit and reassign what they created', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales2);
  update tasks set title = 'hijack' where id = t3;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an unrelated sales_admin cannot update the task (row filtered by policy)', (select title from tasks where id = t3) = 'by assigner');

  -- ---------- re-opening ----------
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'open' where id = %L$q$, t1));
  perform pg_temp.chk('a non-assignee, non-ops user cannot re-open a finished task', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'open' where id = %L$q$, t1));
  perform pg_temp.chk('operations can re-open a finished task', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_pg();

  -- ---------- unassigned task ----------
  t4 := pg_temp.mk(v_org, null, v_ops);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t4));
  perform pg_temp.as_pg();
  -- this sales_admin did not assign the task, so tasks_update_assign hides the row from the update: no error, no row touched. The guard is not reached.
  perform pg_temp.chk('an unassigned task a sales_admin did not assign: the update touches no row and the task stays open (no error is raised)',
    (select status::text from tasks where id = t4) = 'open', coalesce(s, 'no error'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t4));
  perform pg_temp.as_pg();
  perform pg_temp.chk('operations can finish an unassigned task', s is null and (select status::text from tasks where id = t4) = 'done', coalesce(s, 'ok'));
  -- the assigner passes the update policy, so this case reaches guard_task_completion itself
  t4 := pg_temp.mk(v_org, null, v_sales);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t4));
  perform pg_temp.as_pg();
  perform pg_temp.chk('GUARD: the assigner of an unassigned task, who is not operations, is refused by the guard itself and the task stays open',
    s like '%only operations can finish a task that has no assignee%' and (select status::text from tasks where id = t4) = 'open', coalesce(s, 'no error'));

  -- ---------- insert as done ----------
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, assigned_by, title, status) values (%L, %L, %L, 'x', 'done')$q$, v_org, v_tp, v_sales));
  perform pg_temp.chk('a task cannot be created already finished for someone else', s like '%already finished%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, assigned_by, title) values (%L, %L, %L, 'ok')$q$, v_org, v_tp, v_sales));
  perform pg_temp.chk('an open task can still be assigned to anyone', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_pg();

  -- ---------- purchase-order tasks ----------
  insert into suppliers (org_id, name, whatsapp) values (v_org, '__TEST_sup', '9000000199') returning id into v_sup;
  insert into purchase_orders (org_id, supplier_id, status, total) values (v_org, v_sup, 'sent', 10) returning id into v_po;
  insert into purchase_orders (org_id, supplier_id, status, total) values (v_org, v_sup, 'sent', 20) returning id into v_po2;
  t5 := pg_temp.mk(v_org, v_ops, v_master, 'purchase_order', v_po);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t5));
  perform pg_temp.as_pg();
  perform pg_temp.chk('a non-master assignee cannot finish a purchase-order task',
    s like '%only a master%', coalesce(s, 'accepted'));
  perform pg_temp.chk('and the PO was NOT marked paid', (select status::text from purchase_orders where id = v_po) = 'sent');
  t6 := pg_temp.mk(v_org, v_master, v_master, 'purchase_order', v_po2);
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t6));
  perform pg_temp.as_pg();
  perform pg_temp.chk('the master assignee finishes it and the PO is marked paid',
    s is null and (select status::text from purchase_orders where id = v_po2) = 'paid', coalesce(s, 'ok'));
  -- the second, independent check: a non-master reaching the trigger function cannot close the PO even if the guard were absent
  alter table tasks disable trigger aa_guard_task_completion;
  t7 := pg_temp.mk(v_org, v_ops, v_master, 'purchase_order', v_po);
  perform pg_temp.as_user(v_ops);
  update tasks set status = 'done' where id = t7;
  perform pg_temp.as_pg();
  alter table tasks enable trigger aa_guard_task_completion;
  perform pg_temp.chk('with the guard disabled, the PO trigger still refuses a non-master: PO stays sent',
    (select status::text from purchase_orders where id = v_po) = 'sent');
  -- mark_po_paid by the master still works and closes its task
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$select public.mark_po_paid(%L)$q$, v_po));
  perform pg_temp.as_pg();
  perform pg_temp.chk('mark_po_paid by the master still marks the PO paid and closes the task',
    s is null and (select status::text from purchase_orders where id = v_po) = 'paid' and (select status::text from tasks where id = t5) = 'done', coalesce(s, 'ok'));

  -- ref_type escalation: an assignee who is not a master sets ref_type = 'purchase_order' on an ordinary task and finishes it in one update
  insert into purchase_orders (org_id, supplier_id, status, total) values (v_org, v_sup, 'sent', 30) returning id into v_po2;
  t7 := pg_temp.mk(v_org, v_ops, v_master);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set ref_type = 'purchase_order', ref_id = %L, status = 'done' where id = %L$q$, v_po2, t7));
  perform pg_temp.as_pg();
  perform pg_temp.chk('REGRESSION (ref_type escalation): switching a task to purchase_order and finishing it in one update is refused, PO untouched',
    s like '%only a master%' and (select status::text from purchase_orders where id = v_po2) = 'sent', coalesce(s, 'accepted'));

  -- ---------- system paths are exempt ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t1));
  perform pg_temp.chk('a path with no API role (service role / SECURITY DEFINER job / owner) can still set status', s is null, coalesce(s, 'ok'));

  -- ---------- the 'rolled' value: open <-> rolled is not a completion; rolled -> done and done -> rolled follow the same rules ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'rolled' where id = %L$q$, t1));
  perform pg_temp.chk('open -> rolled by the assigner is not restricted by the guard', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t1));
  perform pg_temp.chk('rolled -> done by operations (not the assignee) is refused', s like '%only the person a task is assigned to%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t1));
  perform pg_temp.chk('rolled -> done by the assignee is allowed', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'rolled' where id = %L$q$, t1));
  perform pg_temp.chk('done -> rolled by a non-assignee, non-ops user is refused (same as re-open)', s like '%re-open%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'rolled' where id = %L$q$, t1));
  perform pg_temp.chk('done -> rolled by operations is allowed', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set status = 'open' where id = %L$q$, t1));
  perform pg_temp.chk('rolled -> open by the assignee is allowed', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_pg();

  -- ---------- every path that still has to work after tasks_update_assign was narrowed ----------
  -- (a) Workspace lazy rollover / "Move to today": the assignee rewrites due_date, original_due_date, rolled_count of their OWN task
  t2 := pg_temp.mk(v_org, v_tp, v_tp);
  update tasks set due_date = current_date - 3 where id = t2;
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set original_due_date = coalesce(original_due_date, due_date), due_date = current_date, rolled_count = rolled_count + 1 where id = %L$q$, t2));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH rollover / Move to today: the assignee can move their own task to today',
    s is null and (select due_date from tasks where id = t2) = current_date and (select rolled_count from tasks where id = t2) = 1, coalesce(s, 'ok'));
  -- (b) Workspace quick-add: a self-assigned to-do is inserted and finished by its owner
  perform pg_temp.as_user(v_sales2);
  s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, assigned_by, title, source) values (%L, %L, %L, 'my to-do', 'manual')$q$, v_org, v_sales2, v_sales2));
  perform pg_temp.chk('PATH workspace quick-add: a self-assigned to-do can be created', s is null, coalesce(s, 'ok'));
  s := pg_temp.raises(format($q$update tasks set status = 'done' where org_id = %L and title = 'my to-do' and assignee_id = %L$q$, v_org, v_sales2));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH workspace quick-add: and finished by its owner',
    s is null and (select status::text from tasks where org_id = v_org and title = 'my to-do') = 'done', coalesce(s, 'ok'));
  -- (c) huddle action items: a staff member creates a task linked to a meeting issue for someone else; that someone finishes it
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, assigned_by, title, ref_type, ref_id, source) values (%L, %L, %L, 'huddle action', 'meeting_issue', gen_random_uuid(), 'assigned')$q$, v_org, v_tp, v_sales));
  perform pg_temp.chk('PATH huddle action item: created by a sales_admin for a technician', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where org_id = %L and title = 'huddle action'$q$, v_org));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH huddle action item: finished by the technician it was assigned to',
    s is null and (select status::text from tasks where org_id = v_org and title = 'huddle action') = 'done', coalesce(s, 'ok'));
  -- (d) the task detail screen: the assigner edits text and priority of a task they created, assignee unchanged
  t3 := pg_temp.mk(v_org, v_tp, v_sales);
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set title = 'retitled', description = 'x', priority = 'urgent' where id = %L$q$, t3));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH task detail: the assigner edits text and priority', s is null and (select assigned_by from tasks where id = t3) = v_sales, coalesce(s, 'ok'));

  -- (d2) the regression this package ports in from pkg1: an unrelated edit by the ASSIGNEE (not the assigner —
  -- the harder direction, since the assignee's own tasks_update_assign path doesn't need assigned_by at all) must
  -- not touch assigned_by, and the original assigner must still hold their tasks_update_assign row afterwards.
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update tasks set priority = 'very_urgent' where id = %L$q$, t3));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH d2a: the assignee''s own unrelated edit leaves assigned_by exactly as it was',
    s is null and (select assigned_by from tasks where id = t3) = v_sales, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$update tasks set description = 'still editable by the assigner' where id = %L$q$, t3));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH d2b: the original assigner can still update the row afterwards (tasks_update_assign''s assigned_by = auth.uid() branch was not displaced)',
    s is null and (select description from tasks where id = t3) = 'still editable by the assigner', coalesce(s, 'ok'));
  -- (e) SECURITY DEFINER / service paths are not narrowed
  t4 := pg_temp.mk(v_org, v_master, v_master, 'purchase_order', gen_random_uuid());
  update tasks set due_at = now() - interval '4 days' where id = t4;
  s := pg_temp.raises(format($q$select public.wa_escalate_overdue_po_payment_reminders(%L)$q$, v_org));
  perform pg_temp.chk('PATH PO payment-reminder escalation (service role): still stamps escalated_at',
    s is null and (select escalated_at is not null from tasks where id = t4), coalesce(s, 'ok'));
  t5 := pg_temp.mk(v_org, v_tp, v_sales);
  update tasks set is_recurring = true, due_date = current_date - 1 where id = t5;
  s := pg_temp.raises(format($q$select public.advance_recurring_tasks(%L)$q$, v_org));
  perform pg_temp.chk('PATH recurring tasks (service role): the successor is created for the same assignee',
    s is null and exists (select 1 from tasks where ref_type = 'recurring_task_series' and ref_id = t5 and assignee_id = v_tp), coalesce(s, 'ok'));
  -- (f) not a task update at all: confirmation calls live on appointments.confirmation_called_at
  perform pg_temp.chk('PATH confirmation calls do not touch tasks (appointments.confirmation_called_at)',
    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'appointments' and column_name = 'confirmation_called_at'));

  -- ---------- org scope ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none of these tasks', n = 0, n::text);

  -- ---------- real data: relative to the baseline the wrapper took before the migration ----------
  begin
    v_base := current_setting('gv.baseline', true);
    v_now := pg_temp.gv_fingerprint();
    perform pg_temp.chk('the REAL organisations are unchanged by the migration and these tests (fingerprint equals the pre-migration baseline)',
      v_base is not null and v_base = v_now, coalesce(left(v_base, 40), 'no baseline') || ' / ' || coalesce(left(v_now, 40), '-'));
  exception when undefined_function then
    perform pg_temp.chk('real-data fingerprint skipped: this file was not run through the wrapper (no baseline)', true);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
