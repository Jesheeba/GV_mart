# Feature: water-solution-followup (recommended solution + follow-up task)

## Purpose
After recording a customer's water problems and hardness, staff note a **recommended solution** (often a product the customer doesn't own yet) and a **follow-up date**. Setting the date creates a task on the Tasks page for the master. The master can **postpone** it or **convert it to a lead**.

## Existing pieces reused (no new reminder system)
- `tasks` with `ref_type`/`ref_id`, `source='system'`. Same pattern as `arrival_location_mismatch` and `customer_outstanding`.
- `tasks_notify_assigned` trigger: the master gets an in-app notification when the task is created.
- `zz_tasks_log_changes`: every due-date change is logged as `due_moved` (postpone audit for free).
- Convert to lead: the existing `newLeadForCustomer` navigation state → `NewLeadForm` (staff pick source and product type; the auto-assign and initial follow-up triggers run as usual).

## Architecture
- `customers.water_recommended_solution text` (≤500), edited in the same Water & household fields. Covered by `guard_water_profile_edit_roles`.
- **Single store for the date: the open task's `due_date`.** There is no date column on customers, so postponing on the Tasks page is automatically what the customer form shows.
- RPC `set_customer_water_followup(p_customer_id, p_due_date)` (SECURITY DEFINER):
  - Caller must be master/sales_admin/operation_admin of the customer's org. The date must be today (IST) or later.
  - Upserts the one open task `ref_type='customer_water_followup'`, `ref_id=customer` (partial unique index). Assignee is the oldest active master. `assigned_by` is the caller, so a sales_admin can also see it under tasks RLS.
  - Title and description are built from the problems + solution.
  - `p_due_date = null`: the open task is closed (`done`) with a log note.
- RPC `get_customer_water_followup(p_customer_id)` returns the open task's id + due_date for the form/detail page.
- Tasks page (`TaskDetailDialog`), for this ref_type only:
  - **Postpone**: a later date + a required reason; the reason goes into the `task_logs` note.
  - **Convert to lead**: opens New Lead prefilled for the customer, with notes = problems + solution. When the lead saves, RPC `close_water_followup_as_lead(task_id, lead_id)` closes the task and logs the lead id.

## Impact map
- `tasks` (new ref_type, new partial unique index). The completion guard is bypassed only inside SECURITY DEFINER (`current_user` is not `authenticated`), same as the other system tasks.
- `WaterHouseholdFields` / `WaterHouseholdPanel` / `CustomerFormPage` (date + solution inputs). `TaskDetailDialog`, `LeadsPage`/`NewLeadForm` (carry `fromTaskId`).
- Notifications: only the existing `task_assigned`. No new cron.

## Edge cases
- Past date: rejected in UI and RPC. Same date re-saved: no-op. Date changed: one task, due moved (logged).
- Date cleared: the open task is closed. Customer from another org: refused. No active master: falls back to the caller as assignee.
- Two staff saving at once: the unique index plus `on conflict` leaves one open task.
- Convert to lead abandoned (form cancelled): the task stays open. A lead already created for that task: idempotent close.
- Task done/deleted: the form shows no date; setting a new date creates a fresh task.

## Acceptance criteria
1. Save with a date: exactly one open task for the master, due that date, title naming the customer, and a notification sent.
2. Change the date in the form: the same task moves. Postpone on Tasks: the customer form shows the new date.
3. Clear the date: the task is closed.
4. Convert to lead: a lead is created for that customer with the notes prefilled, and the task is closed with the lead linked.
5. Postpone without a reason, or to an earlier date: blocked.
