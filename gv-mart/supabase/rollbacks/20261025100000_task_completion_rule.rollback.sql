-- Rollback for 20261025100000_task_completion_rule.sql
drop trigger if exists aa_guard_task_status_change on public.tasks;
drop function if exists public.guard_task_status_change();

-- original definition (20260701091200_functions_triggers.sql): no is_active test
create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;
