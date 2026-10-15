-- P1a: task completion rule. Design: only the ASSIGNEE can set a task to 'done'.
--
--   * complete (status -> 'done'): OLD.assignee_id must equal auth.uid(). OLD on purpose, so reassigning to
--     yourself and completing in one statement is still refused. A purchase_order task additionally needs
--     is_master() (the same gate as approve_purchase_order and mark_po_paid).
--   * master / operation_admin may still edit, reassign and REOPEN a finished task; they cannot complete one
--     on someone's behalf.
--   * reopen (done -> anything else): the assignee, or master / operation_admin. open <-> rolled is not a
--     completion and is left as it was.
--   * exempt: every role that is not 'authenticated' or 'anon' (service-role jobs, security-definer
--     functions such as mark_po_paid and advance_recurring_tasks, migrations). Same test as the other guard_*
--     triggers in this schema.
--   * INSERT: a task cannot be created already done for someone else, nor an already-done purchase_order task
--     by a non-master.
--
-- Status column ONLY. The earlier guard (aa_guard_task_assignee_update, 20261006190000) compared every
-- column and was dropped in 20261006200000 because it blocked the task-assignment design (any staff role or
-- technician may create, edit and reassign any task). That behaviour is deliberately untouched here:
-- tasks_select_internal / tasks_insert_assign / tasks_update_assign / tasks_delete_ops are not changed.
--
-- Unassigned tasks (assignee_id is null, possible after the assignee's profile is deleted: ON DELETE SET NULL)
-- cannot be completed until someone reassigns them; reassignment stays open to every staff role.
--
-- current_technician_id() is NOT changed here; see 20261101110000.

create or replace function public.guard_task_status_change()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- service role, security-definer functions and migrations are not 'authenticated'
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'done' and new.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: only the assignee can mark a task done' using errcode = '42501';
    end if;
    if new.status = 'done' and new.ref_type = 'purchase_order' and not public.is_master() then
      raise exception 'tasks: only a user who may approve purchase orders can complete a purchase-order task' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  if new.status = 'done' then
    -- OLD.assignee_id on purpose: changing the assignee and the status in one statement must not let a
    -- non-assignee complete the task.
    if old.assignee_id is null or old.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: only the assignee can mark a task done' using errcode = '42501';
    end if;
    if old.ref_type = 'purchase_order' and not public.is_master() then
      raise exception 'tasks: only a user who may approve purchase orders can complete a purchase-order task' using errcode = '42501';
    end if;
  elsif old.status = 'done' then
    if old.assignee_id is distinct from auth.uid() and not public.is_ops_staff() then
      raise exception 'tasks: only the assignee or operations staff can reopen a task' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- A trigger function is not an RPC: nobody calls it directly, and a trigger fires without EXECUTE on it.
revoke all on function public.guard_task_status_change() from public, anon, authenticated;

drop trigger if exists aa_guard_task_status_change on public.tasks;
create trigger aa_guard_task_status_change
  before insert or update on public.tasks
  for each row execute function public.guard_task_status_change();
