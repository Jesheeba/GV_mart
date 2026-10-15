-- Rollback for 20261101100000_task_status_guard.sql
drop trigger if exists aa_guard_task_status_change on public.tasks;
drop function if exists public.guard_task_status_change();
