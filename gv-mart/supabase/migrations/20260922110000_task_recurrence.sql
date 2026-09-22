-- Monthly recurring tasks ("EB bill", "salary processing" — same day every
-- month), scoped narrowly per the approved design: no RRULE, no custom
-- intervals, just "repeat monthly on this day."
--
-- One new column — no `recurrence_day`, since the day is already
-- `due_date`; a separate column would just be redundant, driftable state.
-- Lineage between a recurring task's instances reuses the existing
-- `ref_type`/`ref_id` columns (the same ones
-- 20260922100000_supplier_credit_terms_and_po_payment_reminder_tasks.sql
-- just established the convention for), under a distinct tag
-- ('recurring_task_series') so the two mechanisms never collide even
-- though they share columns — that migration's tasks are one-shot and
-- system-generated (assigned_by null) from a PO event; these are
-- indefinitely-repeating and human-initiated, and per the approved design
-- carry the original assigned_by forward so the assignee genuinely gets a
-- fresh "task assigned" notification each cycle (or stays silent, same as
-- any other self-assigned task, via the existing skip-on-self-assign logic
-- in _notify_task_assigned).
--
-- Trigger point is date-driven, matching this codebase's only other
-- recurring mechanism (run_rental_billing, 20260915160000): due_date
-- passing advances the series regardless of whether the current instance
-- was ever marked done — a stale, un-completed "EB bill" task must not
-- silently break next month's reminder. Hooked into the existing daily
-- wa-scheduled-tasks pass, same as rental billing / monthly RFQ / the PO
-- payment-reminder escalation — no new cron surface.

alter table public.tasks
  add column if not exists is_recurring boolean not null default false;

alter table public.tasks
  add constraint tasks_recurring_needs_due_date check (not is_recurring or due_date is not null);

-- Idempotent by construction: once a successor exists (linked via
-- ref_type='recurring_task_series', ref_id=<this task's id>), the
-- `not exists` guard excludes this row from matching again — no separate
-- "already generated" marker column needed. Safe to call on every tick;
-- a task not yet due is simply not selected.
create or replace function public.advance_recurring_tasks(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task record;
  v_count integer := 0;
begin
  for v_task in
    select t.*
    from public.tasks t
    where t.org_id = p_org_id
      and t.is_recurring = true
      and t.due_date <= current_date
      and not exists (
        select 1 from public.tasks nxt
        where nxt.ref_type = 'recurring_task_series' and nxt.ref_id = t.id
      )
  loop
    insert into public.tasks (
      org_id, assignee_id, assigned_by, title, description, priority,
      due_date, due_at, is_recurring, ref_type, ref_id
    ) values (
      v_task.org_id, v_task.assignee_id, v_task.assigned_by, v_task.title, v_task.description, v_task.priority,
      v_task.due_date + interval '1 month',
      case when v_task.due_at is not null then v_task.due_at + interval '1 month' else null end,
      true, 'recurring_task_series', v_task.id
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.advance_recurring_tasks(uuid) to service_role;
