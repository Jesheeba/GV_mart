# P3: task work log, task visibility, per-person colour, no silent rollover

Status: BUILT on `feat/p3-task-log-visibility` (P2 + P1 merged in), NOT applied (migration `20261103100000_task_logs_and_visibility`).
Source: client list 12-10-2026 items 4, 5, 6; owner decisions of 2026-10-15 (visibility: master and operations see all, others see their
own and the ones they assigned).
Depends on: P1a `20261101100000`, P1b `20261101110000`, P2 `20261102100000` (`profiles.task_color`). Apply in that order.

## What changes
1. **Work log** (`task_logs`, append-only). A person adds a note, minutes spent, and what is planned next and when. The database also writes
   an entry for every reassignment (who, from whom, to whom; names stored), every status change and every due-date move, whoever made it.
   Nobody can edit or delete an entry through the API, not even the master (a correction is a new entry). The author and time are stamped by
   the database; a client that sends someone else's name, or a system kind, gets its own name and a plain note.
2. **Visibility** (`tasks_select_internal`): master and operation_admin see every task of the organisation; sales_admin and technicians see
   the tasks assigned to them and the tasks they assigned. Insert, update and delete policies are unchanged. The log follows the task: you
   read and add to the log of a task you can see, nothing else.
3. **Colour**: the assignee's `profiles.task_color` (P2) is a dot on the list row and a thick left edge on the calendar event. Overdue stays red
   (P1); the colour never replaces it.
4. **No silent rollover**: the My Workspace list used to rewrite `due_date` of every overdue task on every fetch, which made overdue work
   disappear and wrote no history. It now shows overdue tasks red with a **Move to today** button; the move is the assignee's explicit act and
   is recorded in the work log.

## Who can do what (after P1 + P3)
| | master | operation_admin | assigner (sales_admin) | assignee | unrelated staff / technician |
|---|---|---|---|---|---|
| see the task and its log | all | all | their own assigned | yes | no |
| add a log note | yes | yes | yes | yes | no (cannot see it) |
| edit / reassign | yes | yes | yes (their own) | yes | no |
| finish | only if assignee (PO task: master) | only if assignee | only if assignee | yes | no |

## Behaviour to know
- **Reassigning away loses visibility.** A sales_admin who created a task and then has it reassigned by operations (who becomes `assigned_by`)
  no longer sees it. Operations and master still do. This follows the rule as decided ("their own and the ones they assigned").
- **Daily Huddle action items** are tasks. A non-operations staff member now sees only the action items assigned to or by them on the huddle
  card. Operations and master see all.
- **Reminder tasks** (PO payment reminders, recurring series) are created by the system with no signed-in actor; their log entries show "The
  system". Recurring advance and escalation write log entries as the service role.
- **Actor names are a snapshot**: a person renamed later keeps the old name on old entries (that is what was true at the time). Technicians
  cannot read other people's profile rows, which is why the names are stored on the entry instead of joined.
- Log entries are removed with their task (operations can delete a task; the log goes with it). Anything that must outlive a task belongs
  in `audit_log`, not here.
- Tamil strings for the new labels are English placeholders (same as P1/P2), for the translator.

## Not built, needs the owner
- **Merging My Workspace into Tasks as one "My Day" tab.** I could not confirm the client's exact wording from this conversation, and it is
  a navigation change (route, nav entry, the confirmation-call card, the notifications feed). The other window's branch
  `pkg3/task-logs-colours-workspace-merge` did this merge; its migration uses the same version `20261103100000` and the same table name, so
  **the two cannot both be applied**. Choose one. If the merge is wanted on top of this branch: 0.5 day.
- Per-person colour choice by the person themselves (only the master changes colours, P2).

## Screens changed
Task detail dialog (work-log panel), Tasks list (colour dot), Task calendar (colour edge), My Workspace (overdue red, Move to today, no
automatic rollover). No new routes.

## Estimate
Built: DB 0.5 day, work-log UI 0.5, colour and Move-to-today 0.25, tests and wrapper 0.5 = **1.75 days**. Remaining 0.5 day = rehearsal
run and fixes 0.25, browser pass of the task dialog and workspace on desktop and the Capacitor build 0.25.

## Rollback
`supabase/rollbacks/20261103100000_task_logs_and_visibility.rollback.sql` restores the previous select policy and drops the log, and
refuses while any log entry exists, so after go-live it is unusable (a forward fix is the only way back).

## Deploy order
Migration, then front end. The front end reads `task_logs`; before the migration the dialog's log panel shows "could not load" and nothing
else breaks. Do not apply before P1a, P1b and P2.
