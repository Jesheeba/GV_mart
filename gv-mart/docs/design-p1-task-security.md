# P1: task completion rule, PO-paid fix, active technician, overdue styling

Status: BUILT on `feat/p1-task-security`, NOT applied (migration `20261101100000_task_completion_rule`). Cut from origin/main 0101955.
Source: client list 12-10-2026 item 6 and the read-only security audit; owner decisions of 2026-10-15.

## Rules (decided)
- Only the assignee sets a task done. Master and operation_admin may reassign, never finish for someone. Unassigned task: operations may finish it.
- Re-opening a finished task: the assignee or operations. A task cannot be created already done for someone else.
- A purchase_order task: only a master finishes it (the role that approves and pays POs). `_po_task_completed_marks_paid` re-checks the same,
  so a signed-in non-master never marks a PO paid by ticking its task. Service role and scheduled jobs are exempt.
- `current_technician_id()` is NULL for a deactivated technician, so RLS keyed on it stops matching.
- `tasks_update_assign`: operations, the assignee or the assigner may update (was: any staff or technician).

## Verified before building
Guard history: `20261006190000` froze every column but status/due date for a non-ops assignee; `20261006200000` dropped it because
the assignment system (`20260921160000`) lets any user edit and reassign tasks, which the guard broke. This guard touches only the
done transition and insert-as-done, never title, description, priority, due dates or assignee; regression tests assert that.

## Screens
Tasks list (admin and technician): overdue rows red with an Overdue badge, sorted overdue first then by due day, finished last; the
finish control is disabled with an explanation for anyone who may not finish the task; the database's refusal text is shown if it is
attempted. Calendar: overdue events red with a left bar. Task detail: same disabled toggle; editing text no longer takes over the
"assigned by" field (only a reassignment does), which the visibility rule in P3 depends on.

## Not in P1
Visibility rule, My Workspace merge, rollover replacement (P3). Designation, forced password change (P2).

## Estimate
Built: DB 0.5 day, screens 0.5, tests and wrapper 0.5 = 1.5 days. Remaining: rehearsal 0.25, browser pass 0.25.

## Risks
Deactivating a technician now also removes their task, job and customer-history access immediately (intended).
A PO payment-reminder task assigned to a non-master can no longer be ticked by that person; the master finishes it or reassigns it.
