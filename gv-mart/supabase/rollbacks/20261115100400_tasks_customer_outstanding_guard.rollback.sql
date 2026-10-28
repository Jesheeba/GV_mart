-- Restores tasks_select_internal to its pre-this-migration (post-P3) shape.
drop trigger if exists aaa_guard_customer_outstanding_task_ref on public.tasks;
drop function if exists public._guard_customer_outstanding_task_ref();

drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );
