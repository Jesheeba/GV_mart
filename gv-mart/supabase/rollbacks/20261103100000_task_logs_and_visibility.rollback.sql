-- Rollback for 20261103100000_task_logs_and_visibility. NOT RUN.
-- Refuses while any task_logs row exists: dropping the table would destroy the work history (who reassigned what, and every note).
-- After go-live that is the normal state, so this rollback is only usable before the first log entry is written.
do $rb$
begin
  if exists (select 1 from public.task_logs limit 1) then
    raise exception 'rollback refused: task_logs holds entries; export them first and remove them deliberately';
  end if;
end
$rb$;

-- the visibility policy exactly as 20260921160000 created it
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

drop trigger if exists zz_tasks_log_changes on public.tasks;
drop function if exists public._trg_task_log_changes();
drop table if exists public.task_logs;
drop function if exists public._trg_task_log_client_insert();
drop function if exists public._trg_task_log_immutable();

notify pgrst, 'reload schema';
