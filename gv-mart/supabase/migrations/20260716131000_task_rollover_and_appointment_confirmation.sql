-- ADM-31 Workspace: two audit-flagged gaps.
--
-- 1) Genuine daily to-do rollover. `tasks` previously had no state at all
--    for "this was overdue and got carried forward" — the app just kept
--    matching `due_date <= today AND status != 'done'` in the query, so an
--    old task's due_date silently stayed in the past forever. This adds:
--      - original_due_date: the FIRST due date ever set on the task, so
--        "how many days overdue was this originally" survives repeated
--        rolls (captured once via coalesce(original_due_date, due_date) the
--        first time a task rolls, then never overwritten again).
--      - rolled_count: how many times the task has been carried forward.
--    Nullable/zero-default so existing rows need no backfill. The actual
--    rollover (due_date -> today, rolled_count += 1) is performed lazily by
--    the client the first time an overdue task is fetched (see
--    src/services/workspace.ts listMyWorkspaceTasks) — there is no cron/
--    scheduled-job infrastructure in this project to do it at midnight.
--
-- 2) Per-appointment confirmation-call tracking. The Workspace "Confirmation
--    Call" card used to be one generic button tied to nothing — logging a
--    single notifications row with no link back to which appointment was
--    actually confirmed. confirmation_called_at lets each appointment carry
--    its own log, so the workspace can list today's/tomorrow's unconfirmed
--    appointments individually and drop each one off the list once called.
--    Nullable, no backfill needed (every existing appointment is simply
--    "not yet confirmation-called").

alter table public.tasks
  add column if not exists original_due_date date,
  add column if not exists rolled_count integer not null default 0;

alter table public.appointments
  add column if not exists confirmation_called_at timestamptz;
