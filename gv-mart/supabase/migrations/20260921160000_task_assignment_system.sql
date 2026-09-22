-- Task Assignment System, Phase 0 (2026-09-21)
--
-- Extends the dormant `tasks` table (built for ADM-31 Workspace's personal
-- to-do list, where every row was always self-assigned — see workspace.ts)
-- into a real any-user-to-any-user assignment system with a notification on
-- assignment. Reuses `tasks` rather than a parallel table; reuses the
-- existing `notifications` table/realtime pattern rather than a new
-- delivery mechanism; reuses `priority_level` (already used by service
-- tickets/complaints) rather than a new priority enum.
--
-- Hierarchy is fully open per product decision: any staff role or any
-- technician can assign a task to any other staff role or technician
-- (technician -> master included). Customers are out of scope entirely —
-- no customer-facing surface is added anywhere, and RLS below never grants
-- the customer role access.

alter table public.tasks
  add column if not exists description text,
  add column if not exists priority priority_level not null default 'normal',
  add column if not exists assigned_by uuid references public.profiles (id) on delete set null,
  add column if not exists due_at timestamptz,
  add column if not exists ref_type text,
  add column if not exists ref_id uuid;

-- due_at is additive alongside the existing due_date (date-only) column so
-- Workspace's lazy-rollover logic (services/workspace.ts, which only ever
-- compares due_date) is untouched by this migration. The calendar view
-- (Phase 2) renders a task as an all-day event on due_date when due_at is
-- null, or at that specific time when due_at is set.

create index if not exists tasks_assigned_by_idx on public.tasks (assigned_by);
create index if not exists tasks_org_due_date_idx on public.tasks (org_id, due_date);

-- ── RLS: replace the ops-only write policy with the fully-open hierarchy ──
-- Previously only is_ops_staff() (master/operation_admin) could write a task
-- for someone else; a plain assignee could only flip their own task's
-- status, and technicians couldn't see or touch `tasks` at all. Now any
-- staff role or any technician can see, create and reassign a task for any
-- other staff role or technician. Delete stays ops-only — destructive, and
-- not part of the "assign" requirement this feature is about.

drop policy if exists tasks_write_ops on public.tasks;
drop policy if exists tasks_update_own_assignee on public.tasks;
drop policy if exists tasks_select_staff on public.tasks;

create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

create policy tasks_insert_assign on public.tasks
  for insert with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

create policy tasks_delete_ops on public.tasks
  for delete using (org_id = public.current_org_id() and public.is_ops_staff());

-- ── Notification on assignment ────────────────────────────────────────────
-- Mirrors the appointment_assigned pattern in _auto_assign_ticket_internal:
-- one `notifications` row, type 'task_assigned', to the assignee, skipped
-- on self-assignment (so Workspace's existing self-serve to-do flow, which
-- now passes assigned_by = assignee_id, stays silent). security definer
-- because notifications_insert_ops would otherwise block this insert for
-- any non-ops-staff assigner (RLS on `notifications` only lets
-- is_ops_staff() insert a row for someone else directly).
create or replace function public._notify_task_assigned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assigner_name text;
begin
  if new.assignee_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.assignee_id is not distinct from old.assignee_id then
    return new;
  end if;
  if new.assigned_by is not null and new.assigned_by = new.assignee_id then
    return new;
  end if;

  if new.assigned_by is not null then
    select full_name into v_assigner_name from public.profiles where id = new.assigned_by;
  end if;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  values (
    new.org_id,
    new.assignee_id,
    'task_assigned',
    'New task assigned',
    case when v_assigner_name is not null then format('%s — assigned by %s', new.title, v_assigner_name) else new.title end,
    new.id
  );

  return new;
end;
$$;

drop trigger if exists tasks_notify_assigned on public.tasks;
create trigger tasks_notify_assigned
  after insert or update of assignee_id on public.tasks
  for each row execute function public._notify_task_assigned();
