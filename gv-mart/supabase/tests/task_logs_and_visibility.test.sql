-- DB tests for 20261103100000_task_logs_and_visibility. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
create function pg_temp.mk(p_org uuid, p_assignee uuid, p_by uuid, p_title text default '__TEST_ task') returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, source) values (p_org, p_assignee, p_by, p_title, 'assigned') returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_sales2 uuid; v_tp uuid; v_tp2 uuid; v_tp_off uuid; v_m2 uuid;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; n int; s text; lg public.task_logs; v_base text; v_now text;
begin
  insert into organizations (name) values ('__TEST_p3') returning id into v_org;
  insert into organizations (name) values ('__TEST_p3_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_ops := pg_temp.mkuser('operation_admin', v_org, '__TEST_ Omar Ops');
  v_sales := pg_temp.mkuser('sales_admin', v_org, '__TEST_ Sana Sales');
  v_sales2 := pg_temp.mkuser('sales_admin', v_org, '__TEST_ Sam Sales');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  v_tp2 := pg_temp.mkuser('technician', v_org, '__TEST_ Tim Tech');
  v_tp_off := pg_temp.mkuser('technician', v_org, '__TEST_ Off Tech');
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp_off, true);

  -- ---------- structure ----------
  perform pg_temp.chk('task_logs exists with RLS on, a select and an insert policy, and NO update or delete policy',
    exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'task_logs' and c.relrowsecurity)
    and (select count(*) from pg_policy p where p.polrelid = 'public.task_logs'::regclass and p.polcmd = 'r') = 1
    and (select count(*) from pg_policy p where p.polrelid = 'public.task_logs'::regclass and p.polcmd = 'a') = 1
    and not exists (select 1 from pg_policy p where p.polrelid = 'public.task_logs'::regclass and p.polcmd in ('w', 'd', '*')));
  perform pg_temp.chk('authenticated may only select and insert; anon has nothing',
    has_table_privilege('authenticated', 'public.task_logs', 'SELECT') and has_table_privilege('authenticated', 'public.task_logs', 'INSERT')
    and not has_table_privilege('authenticated', 'public.task_logs', 'UPDATE') and not has_table_privilege('authenticated', 'public.task_logs', 'DELETE')
    and not has_table_privilege('anon', 'public.task_logs', 'SELECT') and not has_table_privilege('anon', 'public.task_logs', 'INSERT'));
  perform pg_temp.chk('the trigger functions are not client-callable',
    not has_function_privilege('authenticated', 'public._trg_task_log_changes()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_task_log_client_insert()', 'execute')
    and not has_function_privilege('anon', 'public._trg_task_log_changes()', 'execute'));

  -- ---------- visibility ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales, 'v-one');       -- assigned to tp, by sales
  t2 := pg_temp.mk(v_org, v_sales2, v_ops, 'v-two');     -- assigned to sales2, by ops
  t3 := pg_temp.mk(v_org, v_tp2, v_tp2, 'v-three');      -- tp2's own to-do
  t4 := pg_temp.mk(v_org, null, v_master, 'v-four');     -- unassigned, by the master
  perform pg_temp.as_user(v_master);
  select count(*) into n from tasks where org_id = v_org and title like 'v-%';
  perform pg_temp.chk('master sees every task of the organisation', n = 4, n::text);
  perform pg_temp.as_user(v_ops);
  select count(*) into n from tasks where org_id = v_org and title like 'v-%';
  perform pg_temp.chk('operation_admin sees every task of the organisation', n = 4, n::text);
  perform pg_temp.as_user(v_sales);
  select count(*) into n from tasks where org_id = v_org and title like 'v-%';
  perform pg_temp.chk('sales_admin sees only the task they assigned (v-one)', n = 1 and exists (select 1 from tasks where title = 'v-one'), n::text);
  perform pg_temp.as_user(v_sales2);
  select count(*) into n from tasks where org_id = v_org and title like 'v-%';
  perform pg_temp.chk('sales_admin sees only the task assigned to them (v-two)', n = 1 and exists (select 1 from tasks where title = 'v-two'), n::text);
  perform pg_temp.as_user(v_tp);
  select count(*) into n from tasks where org_id = v_org and title like 'v-%';
  perform pg_temp.chk('a technician sees only their own task (v-one)', n = 1 and exists (select 1 from tasks where title = 'v-one'), n::text);
  perform pg_temp.as_user(v_tp_off);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.chk('a technician with nothing assigned sees none', n = 0, n::text);
  perform pg_temp.as_pg();
  update technicians set is_active = false where profile_id = v_tp;
  perform pg_temp.as_user(v_tp);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  update technicians set is_active = true where profile_id = v_tp;
  perform pg_temp.chk('a deactivated technician sees none (P1b still applies)', n = 0, n::text);
  perform pg_temp.as_user(v_m2);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none', n = 0, n::text);

  -- the create-then-read paths still work for a non-ops creator (insert ... returning needs the row visible)
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$with x as (insert into tasks (org_id, assignee_id, assigned_by, title, source) values (%L, %L, %L, 'v-created', 'assigned') returning id) select id from x$q$, v_org, v_tp2, v_sales));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH assign: a sales_admin creating a task for a technician can read it back', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$with x as (insert into tasks (org_id, assignee_id, assigned_by, title, source) values (%L, %L, %L, 'v-self', 'manual') returning id) select id from x$q$, v_org, v_tp, v_tp));
  perform pg_temp.as_pg();
  perform pg_temp.chk('PATH quick-add: a technician''s own to-do can be created and read back', s is null, coalesce(s, 'ok'));

  -- ---------- the work log: written by people ----------
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$insert into task_logs (org_id, task_id, note, minutes_spent, next_planned_date, next_planned_note) values (%L, %L, 'Called the customer, no answer', 15, current_date + 1, 'Try again in the morning')$q$, v_org, t1));
  perform pg_temp.as_pg();
  select * into lg from task_logs where task_id = t1 and kind = 'note' limit 1;
  perform pg_temp.chk('the assignee adds a note with minutes and a next-planned date; created_by and actor_name are stamped',
    s is null and lg.created_by = v_tp and lg.actor_name = '__TEST_ Tara Tech' and lg.minutes_spent = 15 and lg.next_planned_date = current_date + 1, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$insert into task_logs (org_id, task_id, note) values (%L, %L, 'Customer rang me instead')$q$, v_org, t1));
  perform pg_temp.chk('the assigner can add a note too', s is null, coalesce(s, 'ok'));
  perform pg_temp.as_user(v_sales2);
  s := pg_temp.raises(format($q$insert into task_logs (org_id, task_id, note) values (%L, %L, 'sneaky note on someone else''s task')$q$, v_org, t1));
  perform pg_temp.as_pg();
  perform pg_temp.chk('someone who cannot see the task cannot log against it', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp);
  insert into task_logs (org_id, task_id, kind, created_by, actor_name, note, from_user, to_user, from_value)
  values (v_org, t1, 'reassigned', v_master, 'Mira Master', 'forged', v_master, v_master, 'x');
  perform pg_temp.as_pg();
  select * into lg from task_logs where task_id = t1 and note = 'forged';
  perform pg_temp.chk('a client cannot forge kind, author or the system columns: stored as a plain note by the caller',
    lg.kind = 'note' and lg.created_by = v_tp and lg.actor_name = '__TEST_ Tara Tech' and lg.from_user is null and lg.to_user is null and lg.from_value is null);
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$insert into task_logs (org_id, task_id) values (%L, %L)$q$, v_org, t1));
  perform pg_temp.as_pg();
  perform pg_temp.chk('an empty note is refused', s like '%task_logs_note_has_content%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$insert into task_logs (org_id, task_id, note, minutes_spent) values (%L, %L, 'too long', 5000)$q$, v_org, t1));
  perform pg_temp.as_pg();
  perform pg_temp.chk('minutes are capped at a day (1440)', s like '%check%', coalesce(s, 'accepted'));

  -- ---------- append-only ----------
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises(format($q$update task_logs set note = 'rewritten' where task_id = %L$q$, t1));
  perform pg_temp.chk('a client cannot update a log entry', s like '%permission denied%' or s like '%cannot be changed%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$delete from task_logs where task_id = %L$q$, t1));
  perform pg_temp.chk('a client cannot delete a log entry', s like '%permission denied%' or s like '%cannot be changed%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$delete from task_logs where task_id = %L$q$, t1));
  perform pg_temp.as_pg();
  perform pg_temp.chk('not even the master can delete one', s like '%permission denied%' or s like '%cannot be changed%', coalesce(s, 'accepted'));
  perform pg_temp.chk('the entries are still there', (select count(*) from task_logs where task_id = t1 and kind = 'note') >= 3);

  -- ---------- who sees the log ----------
  perform pg_temp.as_user(v_tp);
  select count(*) into n from task_logs where task_id = t1;
  perform pg_temp.chk('the assignee reads the log of their task', n >= 3, n::text);
  perform pg_temp.as_user(v_sales2);
  select count(*) into n from task_logs where task_id = t1;
  perform pg_temp.chk('an unrelated sales_admin reads none of it', n = 0, n::text);
  perform pg_temp.as_user(v_ops);
  select count(*) into n from task_logs where task_id = t1;
  perform pg_temp.chk('operations read it', n >= 3, n::text);
  perform pg_temp.as_user(v_m2);
  select count(*) into n from task_logs where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master reads none', n = 0, n::text);

  -- ---------- automatic entries ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales, 'auto-one');
  perform pg_temp.as_user(v_ops);
  update tasks set assignee_id = v_sales2, assigned_by = v_ops where id = t1;
  perform pg_temp.as_pg();
  select * into lg from task_logs where task_id = t1 and kind = 'reassigned';
  perform pg_temp.chk('a reassignment is logged: who, from whom, to whom (names stored)',
    lg.created_by = v_ops and lg.actor_name = '__TEST_ Omar Ops' and lg.from_user = v_tp and lg.to_user = v_sales2
    and lg.from_name = '__TEST_ Tara Tech' and lg.to_name = '__TEST_ Sam Sales');
  perform pg_temp.as_user(v_sales2);
  update tasks set status = 'done' where id = t1;
  perform pg_temp.as_pg();
  select * into lg from task_logs where task_id = t1 and kind = 'status';
  perform pg_temp.chk('finishing is logged with from and to', lg.from_value = 'open' and lg.to_value = 'done' and lg.created_by = v_sales2);
  perform pg_temp.as_user(v_ops);
  update tasks set assignee_id = v_ops, assigned_by = v_ops where id = t1;
  update tasks set status = 'open' where id = t1;
  update tasks set status = 'done' where id = t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('reassigning to oneself and then finishing leaves both reassignments and all three status changes in the log',
    (select count(*) from task_logs where task_id = t1 and kind = 'reassigned') = 2
    and (select count(*) from task_logs where task_id = t1 and kind = 'status') = 3);
  t2 := pg_temp.mk(v_org, v_tp, v_tp, 'auto-two');
  perform pg_temp.as_user(v_tp);
  update tasks set title = 'auto-two renamed', description = 'x', priority = 'urgent' where id = t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('editing text or priority writes no log entry', (select count(*) from task_logs where task_id = t2) = 0);
  update tasks set due_date = current_date - 3 where id = t2;
  perform pg_temp.as_user(v_tp);
  update tasks set original_due_date = coalesce(original_due_date, due_date), due_date = current_date, rolled_count = rolled_count + 1 where id = t2;
  perform pg_temp.as_pg();
  select * into lg from task_logs where task_id = t2 and kind = 'due_moved' and created_by = v_tp;
  perform pg_temp.chk('PATH Move to today: the assignee''s move is logged with the old and new date',
    lg.from_value = (current_date - 3)::text and lg.to_value = current_date::text and lg.actor_name = '__TEST_ Tara Tech');
  -- a service-role path (no signed-in user): logged with no actor
  t3 := pg_temp.mk(v_org, v_tp, v_ops, 'auto-three');
  update tasks set assignee_id = v_tp2 where id = t3;
  perform pg_temp.chk('a path with no signed-in user is logged with no actor',
    exists (select 1 from task_logs where task_id = t3 and kind = 'reassigned' and created_by is null and actor_name is null and to_user = v_tp2));
  -- cascade
  perform pg_temp.as_user(v_ops);
  delete from tasks where id = t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('deleting a task by operations removes its log with it', not exists (select 1 from task_logs where task_id = t1) and not exists (select 1 from tasks where id = t1));

  -- ---------- earlier rules still hold ----------
  t4 := pg_temp.mk(v_org, v_tp, v_ops, 'rule-check');
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t4));
  perform pg_temp.as_pg();
  perform pg_temp.chk('REGRESSION P1a: operations still cannot finish a task assigned to a technician', s like '%only the person a task is assigned to%', coalesce(s, 'accepted'));

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
