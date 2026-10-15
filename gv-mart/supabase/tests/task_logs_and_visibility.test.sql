-- Rolled-back DB tests for 20261103100000_task_logs_and_visibility (P3).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisations only.
-- Depends on P1a (20261101100000) and P2 (20261102100000) already being applied; this file does not re-test either.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_tech boolean default false, p_active boolean default true) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  if p_tech then insert into public.technicians (org_id, profile_id, is_active) values (p_org, v, p_active); end if;
  return v;
end $f$;
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
create function pg_temp.seen(p_uid uuid, p_sql text) returns int language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute 'select count(*) from (' || p_sql || ') q' into n;
  execute 'reset role';
  return n;
exception when others then
  execute 'reset role';
  return -1;
end $f$;

do $t$
declare
  v_org uuid; m uuid; o uuid; s uuid; s2 uuid; t1 uuid; t2 uuid;
  v_mine uuid; v_other uuid; v_bystander uuid; x text; v_log uuid;
begin
  insert into public.organizations(name) values ('__TEST_p3') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org);
  s := pg_temp.mkuser('sales_admin', v_org); s2 := pg_temp.mkuser('sales_admin', v_org);
  t1 := pg_temp.mkuser('technician', v_org, true, true); t2 := pg_temp.mkuser('technician', v_org, true, true);

  -- fixtures: a task t1 is assigned, a task s assigned to t2 (assigned-by s), and a task between two others
  -- neither s2 nor t1/t2 touch
  insert into public.tasks(org_id, assignee_id, assigned_by, title) values (v_org, t1, m, '__TEST_mine') returning id into v_mine;
  insert into public.tasks(org_id, assignee_id, assigned_by, title) values (v_org, t2, s, '__TEST_assigned_by_s') returning id into v_other;
  insert into public.tasks(org_id, assignee_id, assigned_by, title) values (v_org, o, m, '__TEST_bystander') returning id into v_bystander;

  -- V: visibility
  perform pg_temp.chk('V1 master sees every task', pg_temp.seen(m, 'select 1 from public.tasks where org_id = ''' || v_org || '''') = 3);
  perform pg_temp.chk('V2 operation_admin sees every task', pg_temp.seen(o, 'select 1 from public.tasks where org_id = ''' || v_org || '''') = 3);
  perform pg_temp.chk('V3 the assignee (t1) sees their own task', pg_temp.seen(t1, format('select 1 from public.tasks where id = %L', v_mine)) = 1);
  perform pg_temp.chk('V4 the assigner (s) sees a task they assigned to someone else', pg_temp.seen(s, format('select 1 from public.tasks where id = %L', v_other)) = 1);
  perform pg_temp.chk('V5 t1 does NOT see a task assigned to and by other people (the old blanket-technician visibility is gone)',
    pg_temp.seen(t1, format('select 1 from public.tasks where id = %L', v_bystander)) = 0);
  perform pg_temp.chk('V6 sales_admin (s2, uninvolved) sees none of the three',
    pg_temp.seen(s2, 'select 1 from public.tasks where org_id = ''' || v_org || '''') = 0);
  perform pg_temp.chk('V7 t1''s own total visible count is exactly 1 (not the whole org)',
    pg_temp.seen(t1, 'select 1 from public.tasks where org_id = ''' || v_org || '''') = 1);
  perform pg_temp.chk('V8 s''s own total visible count is exactly 1 (assigned-by, not the whole org)',
    pg_temp.seen(s, 'select 1 from public.tasks where org_id = ''' || v_org || '''') = 1);

  -- R: tasks_update_assign / tasks_insert_assign / tasks_delete_ops are UNCHANGED (explicitly out of scope for P3)
  x := pg_temp.act(t2, format('insert into public.tasks(org_id,assignee_id,assigned_by,title) values (%L,%L,%L,''__TEST_t2_creates'')', v_org, s2, t2));
  perform pg_temp.chk('R1 a technician can still create/assign a task for someone wholly uninvolved (unchanged policy)', x = 'ok:1', x);
  x := pg_temp.act(t2, format('update public.tasks set assignee_id = %L where id = %L', t1, v_bystander));
  perform pg_temp.chk('R2 a technician can still reassign a task they cannot even SELECT (unchanged UPDATE policy; the UI simply never shows it to them)', x = 'ok:1', x);
  update public.tasks set assignee_id = o where id = v_bystander;  -- restore the fixture

  -- L: task_logs
  x := pg_temp.act(t1, format('insert into public.task_logs(org_id, task_id, created_by, note, minutes_spent, next_planned_date) values (%L, %L, %L, ''__TEST_called customer'', 25, current_date + 1)', v_org, v_mine, t1));
  perform pg_temp.chk('L1 the assignee can log work on their own task', x = 'ok:1', x);
  select id into v_log from public.task_logs where task_id = v_mine;
  perform pg_temp.chk('L2 created_at/created_by are set and the row is visible to the assignee',
    pg_temp.seen(t1, format('select 1 from public.task_logs where id = %L', v_log)) = 1);
  x := pg_temp.act(t2, format('insert into public.task_logs(org_id, task_id, created_by, note) values (%L, %L, %L, ''__TEST_sneaky'')', v_org, v_mine, t1));
  perform pg_temp.chk('L3 a different technician cannot log work on a task they cannot see', x like 'err:%', x);
  x := pg_temp.act(t1, format('insert into public.task_logs(org_id, task_id, created_by, note) values (%L, %L, %L, ''__TEST_spoof'')', v_org, v_mine, m));
  perform pg_temp.chk('L4 created_by cannot be spoofed to someone else, even on a task the actor CAN see', x like 'err:%', x);
  x := pg_temp.act(t1, format('insert into public.task_logs(org_id, task_id, created_by) values (%L, %L, %L)', v_org, v_mine, t1));
  perform pg_temp.chk('L5 an entry with no note, minutes or next-planned date is refused (the has-content check)', x like 'err:%', x);
  x := pg_temp.act(t1, format('insert into public.task_logs(org_id, task_id, created_by, next_planned_note, next_planned_date) values (%L, %L, %L, ''__TEST_follow up Tuesday'', current_date + 5)', v_org, v_mine, t1));
  perform pg_temp.chk('L6 a plan-only entry (no note, no minutes) is accepted', x = 'ok:1', x);
  x := pg_temp.act(s, format('select 1 from public.task_logs where task_id = %L', v_mine));
  perform pg_temp.chk('L7 an uninvolved sales_admin sees no log entries for a task they cannot see', x = 'ok:0', x);
  perform pg_temp.chk('L8 master/ops sees every log entry regardless of involvement',
    pg_temp.seen(m, format('select 1 from public.task_logs where task_id = %L', v_mine)) = 2);
  x := pg_temp.act(t1, format('update public.task_logs set note = ''__TEST_edited'' where id = %L', v_log));
  perform pg_temp.chk('L9 no update policy: even the author cannot edit a logged entry (append-only)', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(t1, format('delete from public.task_logs where id = %L', v_log));
  perform pg_temp.chk('L10 no delete policy: even the author cannot delete a logged entry', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(t1, format('insert into public.task_logs(org_id, task_id, created_by, minutes_spent) values (%L, %L, %L, 1500)', v_org, v_mine, t1));
  perform pg_temp.chk('L11 minutes_spent is capped at a day (1440)', x like 'err:%', x);
  x := pg_temp.act(o, format('insert into public.task_logs(org_id, task_id, created_by, note) values (%L, %L, %L, ''__TEST_ops note'')', v_org, v_bystander, o));
  perform pg_temp.chk('L12 ops can log work on a task they did not create or are not assigned (master/ops see and can log on every task)', x = 'ok:1', x);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
