-- Water solution follow-up (build-docs/features/water-solution-followup.md, owner decisions 2026-11-26).
--
-- Staff record a recommended solution on the customer's Water & household profile, plus a follow-up date. The date
-- becomes ONE open task for the master (ref_type 'customer_water_followup', ref_id = customer). The task's due_date is
-- the only place the date is stored, so postponing on the Tasks page is exactly what the customer form shows.
-- The master can postpone the task (a later date plus a required reason) or convert it to a lead (closes the task and
-- logs the lead). The existing tasks_notify_assigned trigger notifies the master when the task is created. A daily
-- job at 09:00 IST sends one reminder on the due day.
--
-- Writes go only through the SECURITY DEFINER RPCs below. The tasks completion guard is bypassed there the same
-- way as for every other system task (current_user is the function owner, not 'authenticated').

-- 1. recommended solution on the profile ----------------------------------------------------------------------------------
alter table public.customers
  add column water_recommended_solution text
    check (water_recommended_solution is null or char_length(btrim(water_recommended_solution)) between 1 and 500);

-- The edit guard grows by one column (body otherwise identical to 20261216100000).
create or replace function public.guard_water_profile_edit_roles()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_role public.user_role;
  v_water_changed boolean;
  v_other_changed boolean;
  v_water_cols constant text[] := array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'water_hardness_ppm', 'household_problems', 'water_recommended_solution'];
begin
  if auth.uid() is null then
    return new;
  end if;

  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
    or new.water_hardness_ppm is distinct from old.water_hardness_ppm
    or new.household_problems is distinct from old.household_problems
    or new.water_recommended_solution is distinct from old.water_recommended_solution
  );

  v_other_changed := (
    (to_jsonb(new) - (v_water_cols || array['updated_at']))
    is distinct from
    (to_jsonb(old) - (v_water_cols || array['updated_at']))
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_role is distinct from 'sales_admin' and v_water_changed then
    raise exception 'customers: only master, operation_admin or sales_admin may edit the water profile fields';
  end if;

  return new;
end;
$$;

-- 2. at most one open follow-up task per customer (concurrency-safe dedupe) ---------------------------------------------
create unique index tasks_water_followup_one_open_idx
  on public.tasks (org_id, ref_id)
  where ref_type = 'customer_water_followup' and status = 'open';

-- 3. helpers ---------------------------------------------------------------------------------------------------------------
-- Caller must be master / operation_admin / sales_admin (the roles that may edit the water profile).
create or replace function public._water_followup_caller_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.current_role() in ('master', 'operation_admin', 'sales_admin') $$;
revoke all on function public._water_followup_caller_ok() from public, anon, authenticated;

create or replace function public._water_followup_today()
returns date
language sql
stable
set search_path = public
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;
revoke all on function public._water_followup_today() from public, anon, authenticated;

-- Description shown on the task: what was found plus what to offer. Rebuilt on every save so it never goes stale.
create or replace function public._water_followup_description(p_customer public.customers)
returns text
language sql
stable
set search_path = public
as $$
  select nullif(concat_ws(E'\n',
    case when cardinality(p_customer.household_problems) > 0 then 'Problems faced: ' || array_to_string(p_customer.household_problems, ', ') end,
    case when p_customer.water_hardness_ppm is not null then 'Total hardness: ' || p_customer.water_hardness_ppm::text || ' ppm' end,
    case when p_customer.water_tds_ppm is not null then 'TDS: ' || p_customer.water_tds_ppm::text || ' ppm' end,
    case when p_customer.water_recommended_solution is not null then 'Recommended solution: ' || p_customer.water_recommended_solution end
  ), '')
$$;
revoke all on function public._water_followup_description(public.customers) from public, anon, authenticated;

-- 4. set / move / clear the follow-up date ----------------------------------------------------------------------------------
-- p_due_date null closes the open task (date cleared). The same date re-saved only refreshes the description, so an
-- already-overdue date doesn't fail when the form is re-saved for another reason. A new date must be today or later.
create or replace function public.set_customer_water_followup(p_customer_id uuid, p_due_date date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_customer public.customers;
  v_task_id uuid;
  v_task_due date;
  v_assignee uuid;
  v_actor text;
begin
  if auth.uid() is null or not public._water_followup_caller_ok() then
    raise exception 'water follow-up: not allowed' using errcode = '42501';
  end if;

  select * into v_customer from public.customers where id = p_customer_id and org_id = v_org;
  if not found then
    raise exception 'water follow-up: customer not found' using errcode = 'P0002';
  end if;

  select id, due_date into v_task_id, v_task_due
  from public.tasks
  where org_id = v_org and ref_type = 'customer_water_followup' and ref_id = p_customer_id and status = 'open'
  for update;

  if p_due_date is null then
    if v_task_id is not null then
      select full_name into v_actor from public.profiles where id = auth.uid();
      update public.tasks set status = 'done', updated_at = now() where id = v_task_id;
      insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, note)
      values (v_org, v_task_id, 'note', auth.uid(), v_actor, 'Follow-up date cleared on the customer profile');
    end if;
    return null;
  end if;

  if p_due_date is distinct from v_task_due and p_due_date < public._water_followup_today() then
    raise exception 'water follow-up: the date cannot be in the past' using errcode = '22023';
  end if;

  if v_task_id is not null then
    update public.tasks
    set due_date = p_due_date,
        title = format('Water follow-up: %s', v_customer.name),
        description = public._water_followup_description(v_customer),
        updated_at = now()
    where id = v_task_id;
    return v_task_id;
  end if;

  -- The master is the one reminded. With no active master, fall back to the caller so the task is never orphaned.
  select id into v_assignee
  from public.profiles
  where org_id = v_org and role = 'master' and is_active
  order by created_at asc
  limit 1;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, description, due_date, source, ref_type, ref_id)
  values (
    v_org, coalesce(v_assignee, auth.uid()), auth.uid(),
    format('Water follow-up: %s', v_customer.name),
    public._water_followup_description(v_customer),
    p_due_date, 'system', 'customer_water_followup', p_customer_id
  )
  on conflict (org_id, ref_id) where ref_type = 'customer_water_followup' and status = 'open'
  do update set due_date = excluded.due_date, title = excluded.title, description = excluded.description, updated_at = now()
  returning id into v_task_id;

  return v_task_id;
end;
$$;
revoke all on function public.set_customer_water_followup(uuid, date) from public, anon;
grant execute on function public.set_customer_water_followup(uuid, date) to authenticated;

-- 5. read the open follow-up (tasks RLS hides a master's task from a sales_admin who didn't create it) ----------------
create or replace function public.get_customer_water_followup(p_customer_id uuid)
returns table (task_id uuid, due_date date)
language sql
stable
security definer
set search_path = public
as $$
  select t.id, t.due_date
  from public.tasks t
  where public._water_followup_caller_ok()
    and t.org_id = public.current_org_id()
    and t.ref_type = 'customer_water_followup'
    and t.ref_id = p_customer_id
    and t.status = 'open'
$$;
revoke all on function public.get_customer_water_followup(uuid) from public, anon;
grant execute on function public.get_customer_water_followup(uuid) to authenticated;

-- 6. postpone: a strictly later date (and not in the past) plus a required reason -----------------------------------------
-- Allowed for whoever may update the task under tasks RLS (ops staff, the assignee, the assigner), limited to the
-- water-profile roles. The due_moved log row comes from zz_tasks_log_changes. The reason is a separate note.
create or replace function public.postpone_water_followup(p_task_id uuid, p_new_date date, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task public.tasks;
  v_reason text := nullif(btrim(p_reason), '');
  v_actor text;
begin
  if auth.uid() is null or not public._water_followup_caller_ok() then
    raise exception 'water follow-up: not allowed' using errcode = '42501';
  end if;

  select * into v_task from public.tasks
  where id = p_task_id and org_id = public.current_org_id() and ref_type = 'customer_water_followup'
  for update;
  if not found then
    raise exception 'water follow-up: task not found' using errcode = 'P0002';
  end if;
  if not (public.is_ops_staff() or v_task.assignee_id = auth.uid() or v_task.assigned_by = auth.uid()) then
    raise exception 'water follow-up: not allowed' using errcode = '42501';
  end if;
  if v_task.status <> 'open' then
    raise exception 'water follow-up: the task is already closed' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'water follow-up: a reason (up to 500 characters) is required' using errcode = '22023';
  end if;
  if p_new_date is null or p_new_date < public._water_followup_today() or (v_task.due_date is not null and p_new_date <= v_task.due_date) then
    raise exception 'water follow-up: the new date must be later than the current one and not in the past' using errcode = '22023';
  end if;

  select full_name into v_actor from public.profiles where id = auth.uid();
  update public.tasks set due_date = p_new_date, updated_at = now() where id = p_task_id;
  insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, note, next_planned_date)
  values (v_task.org_id, p_task_id, 'note', auth.uid(), v_actor, 'Postponed: ' || v_reason, p_new_date);
end;
$$;
revoke all on function public.postpone_water_followup(uuid, date, text) from public, anon;
grant execute on function public.postpone_water_followup(uuid, date, text) to authenticated;

-- 7. converted to a lead: close the task and log which lead it became. Idempotent for the same lead. ---------------------
create or replace function public.close_water_followup_as_lead(p_task_id uuid, p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task public.tasks;
  v_lead_customer uuid;
  v_actor text;
  v_note text;
begin
  if auth.uid() is null or not public._water_followup_caller_ok() then
    raise exception 'water follow-up: not allowed' using errcode = '42501';
  end if;

  select * into v_task from public.tasks
  where id = p_task_id and org_id = public.current_org_id() and ref_type = 'customer_water_followup'
  for update;
  if not found then
    raise exception 'water follow-up: task not found' using errcode = 'P0002';
  end if;
  if not (public.is_ops_staff() or v_task.assignee_id = auth.uid() or v_task.assigned_by = auth.uid()) then
    raise exception 'water follow-up: not allowed' using errcode = '42501';
  end if;

  select customer_id into v_lead_customer from public.leads where id = p_lead_id and org_id = v_task.org_id;
  if not found or v_lead_customer is distinct from v_task.ref_id then
    raise exception 'water follow-up: that lead is not for this customer' using errcode = '22023';
  end if;

  v_note := 'Converted to lead ' || p_lead_id::text;
  if v_task.status = 'done' then
    if exists (select 1 from public.task_logs where task_id = p_task_id and kind = 'note' and note = v_note) then
      return;  -- already converted to this lead
    end if;
    raise exception 'water follow-up: the task is already closed' using errcode = '22023';
  end if;

  select full_name into v_actor from public.profiles where id = auth.uid();
  update public.tasks set status = 'done', updated_at = now() where id = p_task_id;
  insert into public.task_logs (org_id, task_id, kind, created_by, actor_name, note)
  values (v_task.org_id, p_task_id, 'note', auth.uid(), v_actor, v_note);
end;
$$;
revoke all on function public.close_water_followup_as_lead(uuid, uuid) from public, anon;
grant execute on function public.close_water_followup_as_lead(uuid, uuid) to authenticated;

-- 8. due-day reminder: one notification per task per due date, 09:00 IST ----------------------------------------------
create or replace function public.notify_due_water_followups()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select t.org_id, t.assignee_id, 'water_followup_due', 'Water follow-up due today', t.title, t.id
  from public.tasks t
  where t.ref_type = 'customer_water_followup'
    and t.status = 'open'
    and t.assignee_id is not null
    and t.due_date = public._water_followup_today()
    and not exists (
      select 1 from public.notifications n
      where n.type = 'water_followup_due' and n.ref_id = t.id
        and (n.created_at at time zone 'Asia/Kolkata')::date = public._water_followup_today()
    );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.notify_due_water_followups() from public, anon, authenticated;
grant execute on function public.notify_due_water_followups() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'water-followup-due') then
    perform cron.unschedule('water-followup-due');
  end if;
  perform cron.schedule('water-followup-due', '30 3 * * *', 'select public.notify_due_water_followups()');
end
$$;

notify pgrst, 'reload schema';
