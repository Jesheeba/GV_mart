-- Accounts follow-up, Feature B, step 5 of 5 — hide customer_outstanding
-- tasks from technicians, and block non-master writes of that ref_type.
--
-- Built on the POST-P3 (integration/p-series, 20261103100000) shape of
-- tasks_select_internal, not the current live one (owner's condition 1):
-- P3 narrows `tasks_select_internal` to
--   (is_staff() or current_technician_id() is not null)
--   and (is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
-- This migration's timestamp sorts after P3's, so by the time it runs for
-- real, P3 will already be live (it is part of the same release window
-- that gates this feature's own apply — see DECISIONS.md). The pre-check
-- below refuses to proceed if the live policy text does not match that
-- expected shape, so this can never silently apply against the wrong
-- baseline.
--
-- Technicians never see a customer_outstanding task at all (spec hard
-- rule); every other ref_type, and every is_staff()/is_ops_staff() path,
-- is untouched. INSERT/UPDATE of ref_type='customer_outstanding' is
-- additionally blocked for anyone but master by a trigger (independent of,
-- and stronger than, the existing tasks_insert_assign/tasks_update_assign
-- policies, which are left exactly as-is). DELETE is already is_ops_staff()
-- -only via the untouched tasks_delete_ops policy.

do $precheck$
declare
  v_live_qual text;
  v_normalized text;
begin
  select replace(qual, E'\r', '') into v_live_qual
  from pg_policies
  where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

  if v_live_qual is null then
    raise exception 'tasks_customer_outstanding_guard: tasks_select_internal policy not found';
  end if;

  v_normalized := regexp_replace(v_live_qual, '\s+', ' ', 'g');

  if v_normalized !~ 'is_ops_staff\(\)' or v_normalized !~ 'assignee_id = auth\.uid\(\)' or v_normalized !~ 'assigned_by = auth\.uid\(\)' then
    raise exception 'tasks_customer_outstanding_guard: live tasks_select_internal does not match the expected post-P3 shape (got: %). Apply P1a/P1b/P2/P3 (integration/p-series) first.', v_normalized;
  end if;
end;
$precheck$;

drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or (public.current_technician_id() is not null and ref_type is distinct from 'customer_outstanding'))
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );

create or replace function public._guard_customer_outstanding_task_ref()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.ref_type = 'customer_outstanding' and not coalesce(public.is_master(), false) then
    raise exception 'tasks: only master may create or modify a customer-outstanding task';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_customer_outstanding_task_ref() from public, anon, authenticated;

drop trigger if exists aaa_guard_customer_outstanding_task_ref on public.tasks;
create trigger aaa_guard_customer_outstanding_task_ref
  before insert or update on public.tasks
  for each row execute function public._guard_customer_outstanding_task_ref();
