-- Reverts the tasks column guard added in 20261006190000.
--
-- That guard assumed the pre-2026-09-21 model (tasks_update_own_assignee:
-- an assignee may only flip their own task's status). 20261006... review
-- found the task-assignment feature (20260921160000_task_assignment_system.sql)
-- deliberately replaced it: any staff role or technician may see, create,
-- edit and REASSIGN any task in their org (tasks_update_assign). The guard
-- would have blocked the app's own edit/reassign flow for an assignee who
-- isn't ops staff, so it is removed. Nothing else changes: the org check in
-- tasks_update_assign stays, delete stays ops-only.
drop trigger if exists aa_guard_task_assignee_update on public.tasks;
drop function if exists public.guard_task_assignee_update();
