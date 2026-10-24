-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): P3 task work log and visibility: migration 20261103100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) stores a baseline fingerprint of the REAL
-- organisations, (4) executes the migration text(s) and then the test file in order, (5) always ends in an unconditional
-- RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5  gv-mart/supabase/migrations/20261103100000_task_logs_and_visibility.sql
--   9ee0ff8755b45aef8db476d5344e4f6bf1bf1bd746691684e3a545433d0b8ec3  gv-mart/supabase/tests/task_logs_and_visibility.test.sql
-- Baseline: before the migration the wrapper stores this fingerprint of the REAL organisations in gv.baseline; the test file
-- recomputes it at the end and checks it is unchanged (a relative comparison, not an absolute count). Fingerprint SQL:
--   select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
--                      from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
--          || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  execute $gvfp$create function pg_temp.gv_fingerprint() returns text language sql stable as $fpb$
select md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
                   from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
       || '|' || (select count(*)::text from public.tasks t where t.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
$fpb$$gvfp$;
  perform set_config('gv.baseline', pg_temp.gv_fingerprint(), true);

  v_text := $rh0$-- P3 (client list 12-10-2026 items 4, 5, 6): who sees which task, and a work log on every task. Design: gv-mart/docs/design-p3-task-log-visibility.md
--
--   1. task_logs            work log per task: a note, minutes spent, what is planned next and when (written by a person), and
--                           automatic entries for every reassignment, status change and due-date move (written by the database).
--                           Append-only: nobody can edit or delete an entry through the API.
--   2. tasks_select_internal narrowed: master and operation_admin see every task of the organisation; everyone else sees the tasks
--                           assigned to them and the tasks they assigned.
--
-- Depends on P1a (20261101100000: guard_task_completion, tasks_update_assign), P1b and P2 (20261102100000: profiles.task_color is
-- read by the screens, not by this file). Nothing here alters those objects.
--
-- Rollback: supabase/rollbacks/20261103100000_task_logs_and_visibility.rollback.sql

-- 1. the work log ---------------------------------------------------------------------------------------------------------
create table public.task_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  kind text not null default 'note' check (kind in ('note', 'reassigned', 'status', 'due_moved')),
  created_by uuid references public.profiles (id) on delete set null,
  actor_name text,
  note text check (note is null or char_length(btrim(note)) between 1 and 2000),
  minutes_spent integer check (minutes_spent is null or minutes_spent between 0 and 1440),
  next_planned_date date,
  next_planned_note text check (next_planned_note is null or char_length(btrim(next_planned_note)) between 1 and 500),
  from_user uuid references public.profiles (id) on delete set null,
  to_user uuid references public.profiles (id) on delete set null,
  from_name text,
  to_name text,
  from_value text,
  to_value text,
  created_at timestamptz not null default now(),
  constraint task_logs_note_has_content check (
    kind <> 'note' or note is not null or minutes_spent is not null or next_planned_date is not null or next_planned_note is not null
  )
);
create index task_logs_task_idx on public.task_logs (task_id, created_at);
create index task_logs_org_idx on public.task_logs (org_id);

alter table public.task_logs enable row level security;
revoke all on public.task_logs from public, anon, authenticated;
grant select, insert on public.task_logs to authenticated;
grant select, insert, update, delete on public.task_logs to service_role;

-- A person sees the log of a task they can see: the subquery runs under the caller's own tasks policy (section 2), so the two rules
-- cannot drift apart.
create policy task_logs_select on public.task_logs for select
  using (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id));
create policy task_logs_insert on public.task_logs for insert
  with check (org_id = public.current_org_id() and exists (select 1 from public.tasks t where t.id = task_logs.task_id and t.org_id = task_logs.org_id));
-- no update or delete policy, and no update or delete privilege: an entry is corrected by adding another one

-- What a client can write is a note by themselves: the database stamps who and when and clears the system-only columns.
-- SECURITY INVOKER on purpose: it tells a client from a trusted path by current_user, which inside a SECURITY DEFINER function is the
-- owner. The only thing it reads is the caller's own profile name, which profiles_select_own (id = auth.uid()) allows.
create or replace function public._trg_task_log_client_insert()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.kind := 'note';
    new.created_by := auth.uid();
    new.actor_name := (select p.full_name from public.profiles p where p.id = auth.uid());
    new.from_user := null;
    new.to_user := null;
    new.from_name := null;
    new.to_name := null;
    new.from_value := null;
    new.to_value := null;
    new.created_at := now();
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_client_insert() from public, anon, authenticated;
create trigger task_logs_client_insert before insert on public.task_logs
  for each row execute function public._trg_task_log_client_insert();

create or replace function public._trg_task_log_immutable()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'task_logs: a log entry cannot be changed or removed';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_immutable() from public, anon, authenticated;
create trigger task_logs_immutable before update or delete on public.task_logs
  for each row execute function public._trg_task_log_immutable();

-- 2. automatic entries ----------------------------------------------------------------------------------------------------
-- Every reassignment (who, from whom, to whom), status change and due-date move is written by the database, whoever made it and
-- through whatever path. P1 accepted that an assigner may reassign a task to themselves and finish it; this is how that stays visible.
-- A path with no signed-in user (service role, scheduled job) is logged with no actor.
create or replace function public._trg_task_log_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor text := (select p.full_name from public.profiles p where p.id = auth.uid());
begin
  if new.assignee_id is distinct from old.assignee_id then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_user, to_user, from_name, to_name)
    values (new.org_id, new.id, 'reassigned', auth.uid(), v_actor, old.assignee_id, new.assignee_id,
            (select p.full_name from public.profiles p where p.id = old.assignee_id),
            (select p.full_name from public.profiles p where p.id = new.assignee_id));
  end if;
  if new.status is distinct from old.status then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'status', auth.uid(), v_actor, old.status::text, new.status::text);
  end if;
  if new.due_date is distinct from old.due_date then
    insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, from_value, to_value)
    values (new.org_id, new.id, 'due_moved', auth.uid(), v_actor, old.due_date::text, new.due_date::text);
  end if;
  return new;
end;
$$;
revoke all on function public._trg_task_log_changes() from public, anon, authenticated;
drop trigger if exists zz_tasks_log_changes on public.tasks;
create trigger zz_tasks_log_changes
  after update of assignee_id, status, due_date on public.tasks
  for each row execute function public._trg_task_log_changes();

-- 3. who sees a task ------------------------------------------------------------------------------------------------------
-- Master and operation_admin: every task of the organisation. Everyone else (sales_admin, technician): the tasks assigned to
-- them and the tasks they assigned. The base condition (staff, or an active technician) is unchanged. Insert, update and delete
-- policies are not touched here.
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

notify pgrst, 'reload schema';
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '99990dde17cceb8485d5adc12bc4776906557a615341a4c0dbd04bf65238d6d5' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261103100000_task_logs_and_visibility.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- DB tests for 20261103100000_task_logs_and_visibility. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
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
  perform pg_temp.chk('_trg_task_log_client_insert and _trg_task_log_immutable are SECURITY INVOKER (they test current_user)',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_trg_task_log_client_insert', '_trg_task_log_immutable') and not prosecdef) = 2);
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
  -- (task_logs does not exist yet when the baseline is taken, so it cannot be part of the fingerprint; no real task is touched here,
  -- therefore no real organisation may have a log entry)
  perform pg_temp.chk('no log entry exists for any REAL organisation',
    not exists (select 1 from public.task_logs l where l.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')));
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
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '9ee0ff8755b45aef8db476d5344e4f6bf1bf1bd746691684e3a545433d0b8ec3' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for task_logs_and_visibility.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
