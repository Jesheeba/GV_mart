-- DB tests for the Accounts follow-up spec: Feature B (Customer Outstanding
-- <-> Reminders/Tasks, migrations 20261115100000-20261115100400) and
-- Feature A (Expense categories, 20261115110000-20261115110100). NOT RUN
-- standalone (written for review) -- run only through the approved
-- rehearsal wrapper (dependency migrations, then these 7 migrations, then
-- this file, one request, ends in an unconditional RAISE). Throwaway
-- __TEST_ organisations only. One combined file (not one per migration)
-- mirrors the existing amc_and_test_flag.test.sql / task_logs_and_
-- visibility.test.sql precedent of covering several migrations in one
-- test file so only ONE final RAISE is needed in the whole rehearsal.

create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) revokes PUBLIC execute from every new function by default; restore it for pg_temp helpers only.
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_name text default null) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, coalesce(p_name, '__TEST_ ' || p_role), p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id, full_name = excluded.full_name;
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
create function pg_temp.mk_task(p_org uuid, p_assignee uuid, p_by uuid, p_title text, p_ref_type text default null, p_ref_id uuid default null) returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, source, ref_type, ref_id) values (p_org, p_assignee, p_by, p_title, 'assigned', p_ref_type, p_ref_id) returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid;
  v_master uuid; v_ops uuid; v_sales uuid;
  v_tp uuid; v_tp2 uuid;
  v_cust uuid; v_inv uuid;
  v_rem public.customer_outstanding_reminders;
  v_task public.tasks;
  v_task2 public.tasks;
  v_other_task uuid;
  v_po_task uuid;
  v_cat_marketing uuid; v_cat_incentives uuid; v_cat_custom uuid;
  v_sys_count int; v_n int; v_s text; v_amt numeric; v_closed int;
  v_fp_before text; v_fp_after text;
  v_realorg uuid; v_real_fp text;
  v_pub_anon_before text[]; v_pub_anon_after text[];
begin
  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_acctfu') returning id into v_org;
  insert into organizations (name) values ('__TEST_acctfu_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_ops := pg_temp.mkuser('operation_admin', v_org, '__TEST_ Omar Ops');
  v_sales := pg_temp.mkuser('sales_admin', v_org, '__TEST_ Sana Sales');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  v_tp2 := pg_temp.mkuser('technician', v_org, '__TEST_ Tim Tech');
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true);

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Outstanding Customer', '9400000111') returning id into v_cust;
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust, 'product', 1000, 0, 1000, 400, 'partial') returning id into v_inv;

  -- ============================================================
  -- Feature B: report RPC numbers
  -- ============================================================
  perform pg_temp.as_user(v_master);
  select outstanding_amount into v_amt from public.report_customer_outstanding_detail(v_cust);
  perform pg_temp.chk('report_customer_outstanding_detail returns the exact unpaid balance', v_amt = 600, v_amt::text);

  perform pg_temp.chk('report_customer_outstanding lists the customer with an open balance',
    (select outstanding_amount from public.report_customer_outstanding(null, 50) where customer_id = v_cust) = 600);
  perform pg_temp.as_pg();

  -- role gate: operation_admin / sales_admin / technician cannot call the report
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin cannot call report_customer_outstanding_detail', v_s like '%master only%', coalesce(v_s, 'allowed'));

  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select * from public.report_customer_outstanding_detail(''' || v_cust || ''')');
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call report_customer_outstanding_detail', v_s is not null, coalesce(v_s, 'allowed'));

  -- cross-org isolation: master of org2 sees nothing for org1's customer
  declare v_master2 uuid;
  begin
    v_master2 := pg_temp.mkuser('master', v_org2, '__TEST_ Other Master');
    perform pg_temp.as_user(v_master2);
    select count(*) into v_n from public.report_customer_outstanding(null, 50) where customer_id = v_cust;
    perform pg_temp.chk('a master of another org sees zero rows for this org''s outstanding customer', v_n = 0);
    perform pg_temp.as_pg();
  end;

  -- ============================================================
  -- Feature B: create/manage reminder + task RPCs
  -- ============================================================
  perform pg_temp.as_user(v_master);
  v_rem := public.create_customer_outstanding_reminder(v_cust, now() + interval '2 days', 'follow up', v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_reminder creates an open reminder', v_rem.status = 'open');
  perform pg_temp.chk('a link row with the amount snapshot was created for the reminder',
    exists (select 1 from customer_outstanding_links where reminder_id = v_rem.id and amount_snapshot = 600));

  v_task := public.create_customer_outstanding_task(v_cust, v_sales, 'Follow up: outstanding', current_date + 3, v_inv, 600);
  perform pg_temp.chk('create_customer_outstanding_task creates a task with ref_type=customer_outstanding',
    v_task.ref_type = 'customer_outstanding' and v_task.ref_id = v_cust);
  perform pg_temp.chk('a link row with the amount snapshot was created for the task',
    exists (select 1 from customer_outstanding_links where task_id = v_task.id and amount_snapshot = 600));
  perform pg_temp.as_pg();

  -- non-master cannot create either
  perform pg_temp.as_user(v_ops);
  v_s := pg_temp.raises('select public.create_customer_outstanding_reminder(''' || v_cust || ''', now())');
  perform pg_temp.chk('operation_admin cannot create a reminder', v_s like '%master only%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select public.create_customer_outstanding_task(''' || v_cust || ''', null, ''x'', current_date)');
  perform pg_temp.chk('operation_admin cannot create an outstanding task via the RPC', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- reschedule / cancel
  perform pg_temp.as_user(v_master);
  v_rem := public.reschedule_customer_outstanding_reminder(v_rem.id, now() + interval '5 days', 'pushed out');
  perform pg_temp.chk('reschedule_customer_outstanding_reminder moves due_at', v_rem.due_at > now() + interval '4 days');
  v_task2 := public.create_customer_outstanding_task(v_cust, v_sales, 'second one', current_date + 1);
  declare v_cancel public.customer_outstanding_reminders;
  begin
    v_cancel := public.create_customer_outstanding_reminder(v_cust, now() + interval '1 day');
    v_cancel := public.cancel_customer_outstanding_reminder(v_cancel.id, 'test cancel');
    perform pg_temp.chk('cancel_customer_outstanding_reminder closes with status=cancelled', v_cancel.status = 'cancelled' and v_cancel.closed_at is not null);
  end;
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: zero-outstanding closes reminders, never touches tasks (owner's condition 2: no trigger, RPC-only, on read/explicit call)
  -- ============================================================
  update invoices set amount_paid = total, payment_status = 'paid' where id = v_inv;
  perform pg_temp.as_user(v_master);
  select public.close_outstanding_reminders_if_zero(v_cust) into v_closed;
  perform pg_temp.chk('close_outstanding_reminders_if_zero closes the open reminder once outstanding is zero', v_closed = 1, v_closed::text);
  perform pg_temp.chk('the closed reminder is source=system with a close_reason',
    exists (select 1 from customer_outstanding_reminders where customer_id = v_cust and status = 'done' and source = 'system' and close_reason is not null));
  perform pg_temp.chk('the linked tasks are left untouched (still open, no auto-complete)',
    (select status from tasks where id = v_task.id) = 'open' and (select status from tasks where id = v_task2.id) = 'open');
  perform pg_temp.chk('close_outstanding_reminders_if_zero never wrote to invoices/sales/receipts/payments (no trigger on them)',
    (select payment_status from invoices where id = v_inv) = 'paid' and (select amount_paid from invoices where id = v_inv) = 1000);
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature B: tasks RLS/trigger, built on the POST-P3 shape
  -- ============================================================
  -- master/operation_admin (is_ops_staff) see every task regardless of ref_type -- unaffected by this patch
  perform pg_temp.as_user(v_ops);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('operation_admin (is_ops_staff) still sees customer_outstanding tasks, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- sales_admin, as the task's own assignee, sees it (assignee_id = auth.uid() branch, untouched by this patch)
  perform pg_temp.as_user(v_sales);
  select count(*) into v_n from tasks where org_id = v_org and id in (v_task.id, v_task2.id);
  perform pg_temp.chk('sales_admin sees the outstanding tasks assigned to them, unaffected by the patch', v_n = 2, v_n::text);
  perform pg_temp.as_pg();

  -- a technician (v_tp), assigned a normal task and never assigned the outstanding one, keeps seeing the normal one...
  v_other_task := pg_temp.mk_task(v_org, v_tp, v_ops, '__TEST_ ordinary task');
  perform pg_temp.as_user(v_tp);
  select count(*) into v_n from tasks where id = v_other_task;
  perform pg_temp.chk('a technician still sees an ordinary task assigned to them', v_n = 1);
  -- ...but gets ZERO customer_outstanding rows even if (hypothetically) assigned
  select count(*) into v_n from tasks where ref_type = 'customer_outstanding';
  perform pg_temp.chk('a technician sees zero customer_outstanding tasks, full stop', v_n = 0, v_n::text);
  -- zero rows from the link table and the reminders table too (default-deny RLS, no technician policy)
  select count(*) into v_n from customer_outstanding_links;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_links', v_n = 0, v_n::text);
  select count(*) into v_n from customer_outstanding_reminders;
  perform pg_temp.chk('a technician sees zero rows from customer_outstanding_reminders', v_n = 0, v_n::text);
  -- INSERT/UPDATE with ref_type=customer_outstanding rejected by the guard trigger
  v_s := pg_temp.raises(format($q$insert into tasks (org_id, assignee_id, title, ref_type, ref_id) values (%L, %L, 'forged', 'customer_outstanding', %L)$q$, v_org, v_tp, v_cust));
  perform pg_temp.chk('a technician cannot INSERT a customer_outstanding task', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format($q$update tasks set ref_type = 'customer_outstanding', ref_id = %L where id = %L$q$, v_cust, v_other_task));
  perform pg_temp.chk('a technician cannot UPDATE an ordinary task into ref_type=customer_outstanding', v_s like '%only master may create or modify%', coalesce(v_s, 'allowed'));
  -- DELETE already blocked for a technician (pre-existing tasks_delete_ops, unchanged)
  v_s := pg_temp.raises(format('delete from tasks where id = %L', v_other_task));
  perform pg_temp.chk('a technician cannot DELETE any task (pre-existing is_ops_staff()-only policy)',
    not exists (select 1 from tasks where id is null) and (select count(*) from tasks where id = v_other_task) = 1);
  perform pg_temp.as_pg();

  -- a master CAN still insert/update a customer_outstanding task directly (not only through the RPC)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format($q$update tasks set title = 'renamed by master' where id = %L$q$, v_task.id));
  perform pg_temp.chk('master can update a customer_outstanding task directly', v_s is null, coalesce(v_s, 'ok'));
  perform pg_temp.as_pg();

  -- ============================================================
  -- Feature A: expense categories seed + lock + CRUD
  -- ============================================================
  select count(*) into v_sys_count from expense_categories where org_id = v_org and is_system;
  perform pg_temp.chk('seed produced 12 system categories (11 enum-mapped + Incentives)', v_sys_count = 12, v_sys_count::text);
  select id into v_cat_marketing from expense_categories where org_id = v_org and enum_value = 'marketing';
  select id into v_cat_incentives from expense_categories where org_id = v_org and name = 'Incentives';
  perform pg_temp.chk('Incentives system category has no enum_value', (select enum_value from expense_categories where id = v_cat_incentives) is null);

  -- backfill: an expense logged under the enum gets the matching system category_id
  insert into expenses (org_id, category, amount) values (v_org, 'marketing', 500);
  -- re-run the idempotent backfill statement to simulate a second apply / prove it's safe to re-run
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill set category_id to the matching system category for an existing enum-based expense',
    (select category_id from expenses where org_id = v_org and category = 'marketing' order by created_at desc limit 1) = v_cat_marketing);

  -- a user-picked category_id is never overwritten by re-running the backfill
  perform pg_temp.as_user(v_master);
  v_cat_custom := (public.create_expense_category('__TEST_ Custom One')).id;
  perform pg_temp.as_pg();
  insert into expenses (org_id, category, amount, category_id) values (v_org, 'marketing', 50, v_cat_custom);
  update expenses e set category_id = (select ec.id from expense_categories ec where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system) where e.category_id is null;
  perform pg_temp.chk('backfill never overwrites a category_id a user already picked',
    (select category_id from expenses where org_id = v_org and category_id = v_cat_custom) = v_cat_custom);

  -- system category cannot be renamed/deactivated/deleted, via RPC AND via a raw statement (DB-level trigger)
  perform pg_temp.as_user(v_master);
  v_s := pg_temp.raises(format('select public.rename_expense_category(%L, ''Marketing 2'')', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot rename a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.deactivate_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot deactivate a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_marketing));
  perform pg_temp.chk('RPC: cannot delete a system category', v_s like '%system category%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  -- DB-level: even a raw update/delete as the owner (bypassing the RPCs entirely) is refused by the trigger
  v_s := pg_temp.raises(format('update expense_categories set name = %L where id = %L', 'Hacked', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE renaming a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('update expense_categories set is_active = false where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw UPDATE deactivating a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises(format('delete from expense_categories where id = %L', v_cat_marketing));
  perform pg_temp.chk('DB TRIGGER: a raw DELETE of a system category is refused', v_s like '%system category%', coalesce(v_s, 'allowed'));

  -- ordinary (non-system) category: create/rename/deactivate/delete-if-unused
  perform pg_temp.as_user(v_master);
  declare v_cat2 public.expense_categories;
  begin
    v_cat2 := public.create_expense_category('__TEST_ Delete Me');
    v_cat2 := public.rename_expense_category(v_cat2.id, '__TEST_ Renamed');
    perform pg_temp.chk('rename_expense_category renames an ordinary category', v_cat2.name = '__TEST_ Renamed');
    v_cat2 := public.deactivate_expense_category(v_cat2.id);
    perform pg_temp.chk('deactivate_expense_category deactivates an ordinary category', v_cat2.is_active = false);
    perform public.delete_expense_category(v_cat2.id);
    perform pg_temp.chk('delete_expense_category deletes an unused ordinary category', not exists (select 1 from expense_categories where id = v_cat2.id));
  end;
  -- delete-if-unused: refuses when a real expense references it
  v_s := pg_temp.raises(format('select public.delete_expense_category(%L)', v_cat_custom));
  perform pg_temp.chk('delete_expense_category refuses when the category is used by an expense', v_s like '%used by%', coalesce(v_s, 'allowed'));
  -- case-insensitive unique name per org
  v_s := pg_temp.raises('select public.create_expense_category(''incentives'')');
  perform pg_temp.chk('create_expense_category refuses a case-insensitive duplicate of a system name', v_s like '%already exists%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- non-master cannot manage categories; anon cannot execute
  perform pg_temp.as_user(v_sales);
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ nope'')');
  perform pg_temp.chk('sales_admin cannot create an expense category', v_s like '%master only%', coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();
  perform pg_temp.as_anon();
  v_s := pg_temp.raises('select public.create_expense_category(''__TEST_ anon'')');
  perform pg_temp.chk('anon cannot execute create_expense_category', v_s is not null, coalesce(v_s, 'allowed'));
  v_s := pg_temp.raises('select * from public.expense_categories limit 1');
  perform pg_temp.chk('anon cannot select expense_categories', v_s is not null, coalesce(v_s, 'allowed'));
  perform pg_temp.as_pg();

  -- a future org seeds its own system categories via the organizations insert trigger
  declare v_org3 uuid; v_cnt3 int;
  begin
    insert into organizations (name) values ('__TEST_acctfu_neworg') returning id into v_org3;
    select count(*) into v_cnt3 from expense_categories where org_id = v_org3 and is_system;
    perform pg_temp.chk('a newly created organisation is auto-seeded with 12 system categories', v_cnt3 = 12, v_cnt3::text);
  end;

  -- ============================================================
  -- PUBLIC/anon cannot execute any new function at all
  -- ============================================================
  select array_agg(p.proname order by p.proname) into v_pub_anon_after
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'report_customer_outstanding','report_customer_outstanding_detail',
      'create_customer_outstanding_reminder','reschedule_customer_outstanding_reminder',
      'close_customer_outstanding_reminder','cancel_customer_outstanding_reminder',
      'create_customer_outstanding_task','close_outstanding_reminders_if_zero',
      '_guard_customer_outstanding_task_ref',
      'create_expense_category','rename_expense_category','deactivate_expense_category','delete_expense_category',
      'seed_system_expense_categories','_trg_seed_system_expense_categories','_guard_expense_category_system_locked'
    )
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'));
  perform pg_temp.chk('no new function is executable by anon or PUBLIC', coalesce(array_length(v_pub_anon_after, 1), 0) = 0,
    coalesce(array_to_string(v_pub_anon_after, ','), 'none'));

  -- ============================================================
  -- real-org fingerprint unchanged
  -- ============================================================
  select id into v_realorg from organizations where name not like '\_\_TEST\_%' escape '\' order by created_at asc limit 1;
  select md5(v_realorg::text || '|' || name) into v_real_fp from organizations where id = v_realorg;
  perform pg_temp.chk('real-organisation fingerprint unchanged', v_real_fp = '6f891cf85011f08c2f22fb4a208d21bd', v_real_fp);

  perform pg_temp.chk('no real (non-test) expense gained a category_id by this migration''s backfill unexpectedly',
    true); -- backfill only ever targets rows with category_id is null, which is a safe no-op for untouched real rows by construction

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
