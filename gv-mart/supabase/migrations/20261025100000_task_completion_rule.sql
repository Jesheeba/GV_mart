-- Package 1: task completion rule + active-only current_technician_id().
--
-- 1. Only the ASSIGNEE can set a task to 'done'. Master/operation_admin may still
--    edit, reassign and reopen (they must not complete on someone's behalf).
--    A purchase-order task additionally needs a user who may approve/mark-pay
--    purchase orders (is_master(), the same gate as approve_purchase_order and
--    mark_po_paid).
-- 2. Service-role jobs (rollover, escalation, recurring clone) and SECURITY
--    DEFINER functions (mark_po_paid) run as a non-authenticated role and are
--    exempt. Same current_user test as the other guard_* triggers.
-- 3. The guard looks at the STATUS column only. The earlier guard
--    (aa_guard_task_assignee_update, 20261006190000) compared every column and
--    was dropped in 20261006200000 because it blocked the task-assignment
--    design: any staff role or technician may create, edit and REASSIGN any task.
--    That behaviour is deliberately left untouched here.
-- 4. current_technician_id() now requires technicians.is_active, so a deactivated
--    technician no longer passes tasks_select_internal / tasks_update_assign (nor
--    any other policy that only tested "current_technician_id() is not null").

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() and is_active $$;

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
    -- OLD.assignee_id on purpose: changing the assignee and the status in one
    -- statement must not let a non-assignee complete the task.
    if old.assignee_id is null or old.assignee_id is distinct from auth.uid() then
      raise exception 'tasks: only the assignee can mark a task done' using errcode = '42501';
    end if;
    if old.ref_type = 'purchase_order' and not public.is_master() then
      raise exception 'tasks: only a user who may approve purchase orders can complete a purchase-order task' using errcode = '42501';
    end if;
  elsif old.status = 'done' then
    -- reopen a finished task: the assignee, or master/operation_admin.
    -- (open <-> rolled moves are not completion and are left as they were)
    if old.assignee_id is distinct from auth.uid() and not public.is_ops_staff() then
      raise exception 'tasks: only the assignee or operations staff can reopen a task' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists aa_guard_task_status_change on public.tasks;
create trigger aa_guard_task_status_change
  before insert or update on public.tasks
  for each row execute function public.guard_task_status_change();
