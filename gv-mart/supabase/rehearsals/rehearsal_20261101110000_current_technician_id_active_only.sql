-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): current_technician_id() active only (P1b): migration 20261101110000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   9be922190b42b468d38331470d12cee8ef793f76ffbfbadde6358734a6e08b65  gv-mart/supabase/migrations/20261101110000_current_technician_id_active_only.sql
--   776cd7f4e4e504d71d7ce2d79dde98ceb54a1b963ae0eeebe2ddc6d77d28c0ac  gv-mart/supabase/tests/current_technician_id_active_only.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- P1b: current_technician_id() resolves only an ACTIVE technician.
--
-- Until now the helper returned the technician row id for any technicians.profile_id = auth.uid(), active or
-- not; 20260730150000 patched that one policy at a time with current_technician_is_active(). Making the base
-- helper itself active-only closes every remaining policy and function that tested only "is not null" or an id
-- match.
--
-- What does NOT change (they do not use this helper):
--   * technicians_select_own (profile_id = auth.uid()) and the profiles row: a deactivated technician can
--     still sign in and still reads their own technicians row, so the "Account deactivated" screen
--     (TechnicianShell) still renders.
--   * every staff policy (is_staff() / is_ops_staff()), including admin_override_visit_completion.
--   * current_technician_is_active(): it calls this helper and coalesces to false, same answer as before.
--
-- Effect, by design: a deactivated technician resolves to NULL, so (a) the 36 policies / 19 functions listed in
-- design-note P1b return no rows / are refused for them, and (b) those functions' own
-- "caller is not a technician" guards fire. A queued offline job from a technician deactivated mid-job fails and
-- goes to the stuck list; it is not silently dropped, and an admin can close the visit.

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() and is_active $$;
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '9be922190b42b468d38331470d12cee8ef793f76ffbfbadde6358734a6e08b65' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261101110000_current_technician_id_active_only.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for 20261101110000_current_technician_id_active_only (P1b).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisations only.
-- One representative per flow that changes, plus the flows that must NOT change:
--   H  the helper itself                    L  technician login / deactivated screen (must NOT change)
--   P  policies that tested only "id match" (appointments, customers via is_technician_customer, stock levels, salaries, tasks)
--   F  functions behind the offline outbox (generate_visit_otp refuses an inactive caller)
--   M  deactivated mid-job: the open visit, then deactivation, then replay
--   S  staff are unaffected
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
-- count rows visible to a user for a select
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
  v_org uuid; m uuid; ta uuid; ti uuid; v_tech_a uuid; v_tech_i uuid;
  v_cust_a uuid; v_cust_i uuid; v_tk_a uuid; v_tk_i uuid; v_ap_a uuid; v_ap_i uuid; v_vis_a uuid; v_vis_i uuid;
  x text;
begin
  insert into public.organizations(name) values ('__TEST_tech_active_only') returning id into v_org;
  m := pg_temp.mkuser('master', v_org);
  ta := pg_temp.mkuser('technician', v_org, true, true);
  ti := pg_temp.mkuser('technician', v_org, true, false);
  select id into v_tech_a from public.technicians where profile_id = ta;
  select id into v_tech_i from public.technicians where profile_id = ti;

  -- fixtures (superuser; RLS bypassed): one customer / ticket / appointment / visit per technician
  insert into public.customers(org_id, name, mobile) values (v_org, '__TEST_cust_a', '9000000001') returning id into v_cust_a;
  insert into public.customers(org_id, name, mobile) values (v_org, '__TEST_cust_i', '9000000002') returning id into v_cust_i;
  insert into public.service_tickets(org_id, customer_id, name_of_complaint) values (v_org, v_cust_a, '__TEST_a') returning id into v_tk_a;
  insert into public.service_tickets(org_id, customer_id, name_of_complaint) values (v_org, v_cust_i, '__TEST_i') returning id into v_tk_i;
  insert into public.appointments(org_id, ticket_id, technician_id, scheduled_at) values (v_org, v_tk_a, v_tech_a, now()) returning id into v_ap_a;
  insert into public.appointments(org_id, ticket_id, technician_id, scheduled_at) values (v_org, v_tk_i, v_tech_i, now()) returning id into v_ap_i;
  insert into public.service_visits(org_id, ticket_id, technician_id) values (v_org, v_tk_a, v_tech_a) returning id into v_vis_a;
  insert into public.service_visits(org_id, ticket_id, technician_id) values (v_org, v_tk_i, v_tech_i) returning id into v_vis_i;
  insert into public.technician_stock_levels(org_id, technician_id, item_type, item_id, stock_qty) values (v_org, v_tech_a, 'spare', gen_random_uuid(), 2);
  insert into public.technician_stock_levels(org_id, technician_id, item_type, item_id, stock_qty) values (v_org, v_tech_i, 'spare', gen_random_uuid(), 2);
  insert into public.salaries(org_id, technician_id, period) values (v_org, v_tech_a, date '2026-09-01');
  insert into public.salaries(org_id, technician_id, period) values (v_org, v_tech_i, date '2026-09-01');
  insert into public.tasks(org_id, assignee_id, title) values (v_org, ta, '__TEST_task_a');
  insert into public.tasks(org_id, assignee_id, title) values (v_org, ti, '__TEST_task_i');

  -- H: the helper
  perform set_config('request.jwt.claims', json_build_object('sub', ta, 'role', 'authenticated')::text, true);
  perform pg_temp.chk('H1 an active technician resolves to their technicians.id', public.current_technician_id() = v_tech_a);
  perform pg_temp.chk('H3 current_technician_is_active() is true for the active technician', public.current_technician_is_active());
  perform set_config('request.jwt.claims', json_build_object('sub', ti, 'role', 'authenticated')::text, true);
  perform pg_temp.chk('H2 a deactivated technician resolves to NULL', public.current_technician_id() is null);
  perform pg_temp.chk('H4 current_technician_is_active() is still false for the deactivated technician', not public.current_technician_is_active());
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  perform pg_temp.chk('H5 a non-technician resolves to NULL (unchanged)', public.current_technician_id() is null);
  perform set_config('request.jwt.claims', '', true);

  -- L: login and the deactivated screen must NOT change
  perform pg_temp.chk('L1 a deactivated technician still reads their own technicians row (is_active = false, for the deactivated screen)',
    pg_temp.seen(ti, format('select 1 from public.technicians where profile_id = %L and is_active = false', ti)) = 1);
  perform pg_temp.chk('L2 a deactivated technician still reads their own profile',
    pg_temp.seen(ti, format('select 1 from public.profiles where id = %L', ti)) = 1);
  perform pg_temp.chk('L3 an active technician reads their own technicians row',
    pg_temp.seen(ta, format('select 1 from public.technicians where profile_id = %L and is_active', ta)) = 1);

  -- P: policies
  perform pg_temp.chk('P1 appointments_select_own_technician: active sees own, deactivated sees none',
    pg_temp.seen(ta, format('select 1 from public.appointments where id = %L', v_ap_a)) = 1
    and pg_temp.seen(ti, format('select 1 from public.appointments where id = %L', v_ap_i)) = 0);
  perform pg_temp.chk('P2 appointments_update_own_technician: active can flip status, deactivated cannot',
    pg_temp.act(ta, format('update public.appointments set status = ''in_progress'' where id = %L', v_ap_a)) = 'ok:1'
    and pg_temp.act(ti, format('update public.appointments set status = ''in_progress'' where id = %L', v_ap_i)) in ('ok:0'));
  perform pg_temp.chk('P3 is_technician_customer (customers and tickets): deactivated no longer sees the customer or ticket',
    pg_temp.seen(ta, format('select 1 from public.customers where id = %L', v_cust_a)) = 1
    and pg_temp.seen(ti, format('select 1 from public.customers where id = %L', v_cust_i)) = 0
    and pg_temp.seen(ti, format('select 1 from public.service_tickets where id = %L', v_tk_i)) = 0);
  perform pg_temp.chk('P4 technician_stock_levels_select_own: deactivated sees none',
    pg_temp.seen(ta, format('select 1 from public.technician_stock_levels where technician_id = %L', v_tech_a)) = 1
    and pg_temp.seen(ti, format('select 1 from public.technician_stock_levels where technician_id = %L', v_tech_i)) = 0);
  perform pg_temp.chk('P5 salaries_select_own: deactivated can no longer read own salary rows (DECISION: see design note)',
    pg_temp.seen(ta, format('select 1 from public.salaries where technician_id = %L', v_tech_a)) = 1
    and pg_temp.seen(ti, format('select 1 from public.salaries where technician_id = %L', v_tech_i)) = 0);
  perform pg_temp.chk('P6 tasks (tasks_select_internal / tasks_update_assign): deactivated technician sees and updates nothing',
    pg_temp.seen(ti, 'select 1 from public.tasks') = 0
    and pg_temp.act(ti, format('update public.tasks set title = ''__TEST_x'' where org_id = %L', v_org)) = 'ok:0'
    and pg_temp.seen(ta, 'select 1 from public.tasks') >= 2);
  x := pg_temp.act(ti, format('insert into public.tasks(org_id, assignee_id, title) values (%L, %L, ''__TEST_ins'')', v_org, ti));
  perform pg_temp.chk('P7 tasks_insert_assign: deactivated technician cannot create a task', x like 'err:%', x);

  -- F: functions behind the offline outbox. generate_visit_otp starts with
  -- "v_tech_id := current_technician_id(); if v_tech_id is null then raise 'caller is not a technician'".
  x := pg_temp.act(ti, format('select public.generate_visit_otp(%L, %L)', v_org, v_vis_i));
  perform pg_temp.chk('F1 generate_visit_otp refuses a deactivated technician', x like 'err:%caller is not a technician%', x);
  x := pg_temp.act(ta, format('select public.generate_visit_otp(%L, %L)', v_org, v_vis_a));
  perform pg_temp.chk('F2 generate_visit_otp does not refuse an active technician for that reason', x not like 'err:%caller is not a technician%', x);

  -- M: deactivated mid-job. The visit is open and belongs to the active technician; deactivate, then the replayed call is refused,
  -- the record survives for staff, and nothing is deleted.
  update public.technicians set is_active = false where id = v_tech_a;
  x := pg_temp.act(ta, format('select public.generate_visit_otp(%L, %L)', v_org, v_vis_a));
  perform pg_temp.chk('M1 the same call, replayed after deactivation mid-job, is refused', x like 'err:%caller is not a technician%', x);
  perform pg_temp.chk('M2 the open visit and appointment are untouched (nothing deleted, nothing completed)',
    (select count(*) from public.service_visits where id = v_vis_a and timer_end is null) = 1
    and (select count(*) from public.appointments where id = v_ap_a) = 1);
  perform pg_temp.chk('M3 staff can still see the stranded appointment and visit to close it',
    pg_temp.seen(m, format('select 1 from public.appointments where id = %L', v_ap_a)) = 1
    and pg_temp.seen(m, format('select 1 from public.service_visits where id = %L', v_vis_a)) = 1);

  -- S: staff unaffected
  perform pg_temp.chk('S1 master reads every task and appointment in the org (staff policies do not use the helper)',
    pg_temp.seen(m, 'select 1 from public.tasks') >= 2 and pg_temp.seen(m, 'select 1 from public.appointments') >= 2);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '776cd7f4e4e504d71d7ce2d79dde98ceb54a1b963ae0eeebe2ddc6d77d28c0ac' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for current_technician_id_active_only.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
