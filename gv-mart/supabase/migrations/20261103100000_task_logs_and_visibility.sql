-- P3: a work log per task, and the task visibility rule.
--
-- Depends on P1a (20261101100000, the status guard) and P2 (20261102100000, profiles.colour) being applied first —
-- not for any object this file references directly, but because the builder applies migrations in filename order and
-- this one assumes tasks already carries the P1a trigger and profiles already carries `colour` (read by the client,
-- not by this migration). Nothing here alters either.
--
-- 1. task_logs: a work-log entry a user adds against a task they can see — a note, minutes spent, and what they plan
--    to do next (and when). Append-only, like audit_log and meeting_issues' own history: no update/delete policy, so
--    a correction is a new entry, not an edit of history. created_by and created_at are stamped from the session,
--    never trusted from the client.
--
-- 2. tasks_select_internal is narrowed: master and operation_admin (is_ops_staff()) keep seeing every task in the
--    org; everyone else (sales_admin, technicians) now sees only tasks where they are the assignee OR the one who
--    assigned it ("assigned-by-me"), not the whole org. tasks_insert_assign / tasks_update_assign / tasks_delete_ops
--    are UNCHANGED (explicitly out of scope — any staff role or technician may still create, edit and reassign any
--    task; see 20261101100000's own comment on why that guard was dropped once already). A row a non-ops user can no
--    longer SELECT is also one the client can no longer discover to update through the UI, which is the intended
--    practical effect; the UPDATE policy itself is left exactly as it was.
--
-- Side effect, called out rather than special-cased: the Daily Huddle's action-item list (tasks with
-- ref_type='meeting_issue') uses this same table and policy. A non-ops user now sees only the action items assigned
-- to them or that they assigned, not every action item on the huddle — consistent with the rule above, not a bug.

-- 1. task_logs ---------------------------------------------------------------------------------------------------
create table public.task_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  created_by uuid references public.profiles (id) on delete set null,
  note text check (note is null or char_length(btrim(note)) between 1 and 2000),
  minutes_spent integer check (minutes_spent is null or minutes_spent between 0 and 1440),
  next_planned_date date,
  next_planned_note text check (next_planned_note is null or char_length(btrim(next_planned_note)) between 1 and 500),
  created_at timestamptz not null default now(),
  constraint task_logs_has_content check (note is not null or minutes_spent is not null or next_planned_date is not null or next_planned_note is not null)
);
create index task_logs_task_id_idx on public.task_logs (task_id, created_at desc);
create index task_logs_org_id_idx on public.task_logs (org_id);

alter table public.task_logs enable row level security;

-- same visibility as the parent task: master/ops see any task's log, everyone else only a task they can see under
-- the rule below (assignee or assigner).
create or replace function public._can_see_task(p_task_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tasks t
    where t.id = p_task_id
      and t.org_id = public.current_org_id()
      and (public.is_ops_staff() or t.assignee_id = auth.uid() or t.assigned_by = auth.uid())
  )
$$;
revoke all on function public._can_see_task(uuid) from public, anon;
grant execute on function public._can_see_task(uuid) to authenticated;

create policy task_logs_select on public.task_logs
  for select using (org_id = public.current_org_id() and public._can_see_task(task_id));
create policy task_logs_insert on public.task_logs
  for insert with check (
    org_id = public.current_org_id()
    and public._can_see_task(task_id)
    and created_by = auth.uid()
  );
-- No update/delete policy: append-only, matching audit_log/meeting_issues history.

-- 2. visibility -------------------------------------------------------------------------------------------------
drop policy if exists tasks_select_internal on public.tasks;
create policy tasks_select_internal on public.tasks
  for select using (
    org_id = public.current_org_id()
    and (public.is_ops_staff() or assignee_id = auth.uid() or assigned_by = auth.uid())
  );
