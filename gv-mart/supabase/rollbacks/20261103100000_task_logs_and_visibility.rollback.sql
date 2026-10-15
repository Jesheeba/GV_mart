-- Rollback for 20261103100000_task_logs_and_visibility.sql

-- original definition (20260921160000_task_assignment_system.sql): any staff role or any technician sees every task
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

drop policy if exists task_logs_insert on public.task_logs;
drop policy if exists task_logs_select on public.task_logs;
drop function if exists public._can_see_task(uuid);
drop table if exists public.task_logs;
