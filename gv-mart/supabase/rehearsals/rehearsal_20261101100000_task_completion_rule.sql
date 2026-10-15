-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): P1 task completion rule: migration 20261101100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   f4d00a54b1eca81fe7a66a2fc2e3cc1a48ace13dedfa263f10221058da4dc830  gv-mart/supabase/migrations/20261101100000_task_completion_rule.sql
--   73e58bfa7d438bc0d50f382013273e8f720d19161a6eb1c7826653a8e2aa64c2  gv-mart/supabase/tests/task_completion_rule.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- P1 (client list 12-10-2026, item 6 + security audit): who may finish a task, and the paths around it.
-- Design: gv-mart/docs/design-p1-task-security.md
--
--   1. Only the person a task is assigned to can set it done. Master and operation_admin may reassign a task but cannot complete it
--      on someone's behalf. An UNASSIGNED task can be completed by operations (someone must). Re-opening a finished task: the
--      assignee or operations. A task cannot be INSERTED already done for someone else.
--   2. A purchase_order task can be completed only by a master (the role that approves and pays POs, mark_po_paid / approve_purchase_order).
--   3. Closing the PO through its task (_po_task_completed_marks_paid) is now conditional on the same: a signed-in non-master never marks
--      a PO paid by ticking a task. Paths with no signed-in user (service role, scheduled jobs) are unchanged.
--   4. current_technician_id() returns NULL for a deactivated technician, so every RLS policy that keys on it stops matching.
--   5. tasks_update_assign: only operations, the assignee or the assigner may update a task (it was: any staff or technician).
--
-- Exempt from the completion guard (current_user is not authenticated/anon): the service role, SECURITY DEFINER functions
-- (mark_po_paid, advance_recurring_tasks, the escalation and PO-reminder jobs, the rollover RPCs) and any direct owner connection.
--
-- WHY THE EARLIER GUARD WAS DROPPED (20261006190000 -> 20261006200000) and how this one differs: that trigger froze every column except
-- status / due_date for a non-ops assignee, which broke the app's own edit and reassign flow once task assignment (20260921160000)
-- let any user create, edit and reassign tasks. This guard restricts ONLY the status transition to done / back from done and the
-- insert-as-done case; it never looks at title, description, priority, due dates or assignee. The regression tests in
-- tests/task_completion_rule.test.sql assert that an assignee can still edit and reassign their own task.
--
-- Rollback: supabase/rollbacks/20261101100000_task_completion_rule.rollback.sql

-- 1. a deactivated technician is not a technician for RLS --------------------------------------------------------------
create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select t.id from public.technicians t where t.profile_id = auth.uid() and t.is_active $$;

-- 2. completion guard --------------------------------------------------------------------------------------------------
create or replace function public.guard_task_completion()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role, SECURITY DEFINER jobs and the owner connection are not subject to this rule
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'done' and new.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: a task cannot be created already finished for someone else';
    end if;
    return new;
  end if;

  if new.status = 'done' and old.status is distinct from 'done' then
    if old.assignee_id is not null then
      if old.assignee_id is distinct from auth.uid() then
        raise exception 'tasks: only the person a task is assigned to can mark it finished';
      end if;
    elsif not public.is_ops_staff() then
      raise exception 'tasks: only operations can finish a task that has no assignee';
    end if;
    if old.ref_type = 'purchase_order' and not public.is_master() then
      raise exception 'tasks: only a master can finish a purchase-order task';
    end if;
  elsif old.status = 'done' and new.status is distinct from 'done' then
    if old.assignee_id is distinct from auth.uid() and not public.is_ops_staff() then
      raise exception 'tasks: only the assignee or operations can re-open a finished task';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_task_completion() from public, anon, authenticated;

drop trigger if exists aa_guard_task_completion on public.tasks;
create trigger aa_guard_task_completion
  before insert or update on public.tasks
  for each row execute function public.guard_task_completion();

-- 3. closing the PO through its task needs a master (or a system path) -------------------------------------------------
create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    -- a signed-in user who is not a master never marks a PO paid by ticking its task (the guard above already refuses the tick;
    -- this is the second, independent check). No signed-in user = service role / scheduled job: unchanged.
    if auth.uid() is not null and not public.is_master() then
      return new;
    end if;
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;

-- 4. who may update a task ----------------------------------------------------------------------------------------------
drop policy if exists tasks_update_assign on public.tasks;
create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'f4d00a54b1eca81fe7a66a2fc2e3cc1a48ace13dedfa263f10221058da4dc830' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261101100000_task_completion_rule.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- DB tests for 20261101100000_task_completion_rule. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
  s text; n int; st text; x uuid;
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
  perform pg_temp.chk('an unassigned task cannot be finished by a sales_admin', s is not null, coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t4));
  perform pg_temp.as_pg();
  perform pg_temp.chk('operations can finish an unassigned task', s is null and (select status::text from tasks where id = t4) = 'done', coalesce(s, 'ok'));

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

  -- ---------- system paths are exempt ----------
  t1 := pg_temp.mk(v_org, v_tp, v_sales);
  s := pg_temp.raises(format($q$update tasks set status = 'done' where id = %L$q$, t1));
  perform pg_temp.chk('a path with no API role (service role / SECURITY DEFINER job / owner) can still set status', s is null, coalesce(s, 'ok'));

  -- ---------- deactivated technician ----------
  perform pg_temp.as_user(v_tp);
  select public.current_technician_id() into x;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an active technician resolves to their technician id', x = v_tech, coalesce(x::text, 'null'));
  update technicians set is_active = false where id = v_tech;
  perform pg_temp.as_user(v_tp);
  select public.current_technician_id() into x;
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a deactivated technician: current_technician_id() is NULL and they can no longer read tasks', x is null and n = 0, coalesce(x::text, 'null') || '/' || n::text);
  t3 := pg_temp.mk(v_org, v_tp, v_ops);
  perform pg_temp.as_user(v_tp);
  update tasks set status = 'done' where id = t3;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a deactivated technician cannot finish a task assigned to them', (select status::text from tasks where id = t3) = 'open');
  update technicians set is_active = true where id = v_tech;

  -- ---------- org scope ----------
  perform pg_temp.as_user(v_m2);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none of these tasks', n = 0, n::text);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '73e58bfa7d438bc0d50f382013273e8f720d19161a6eb1c7826653a8e2aa64c2' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for task_completion_rule.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
