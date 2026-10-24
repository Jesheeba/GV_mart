# pkg1-3 retirement — functional coverage check against Window P, 2026-10-24

`pkg1/task-completion-rule`, `pkg2/staff-huddle-profile` and `pkg3/task-logs-colours-workspace-merge`
are retired: Window P's `feat/p1-task-security` → `feat/p2-staff-profile-huddle` →
`feat/p3-task-log-visibility` (each layered on the last; `feat/p3` is the full cumulative stack)
supersede them. They are out of the rehearsal queue and no longer maintained from this point.

This is not just the collision list — each pkg branch's full diff against the common base
(`0101955`) was compared against `feat/p3-task-log-visibility`'s diff, file by file and, where a
filename didn't carry over, by reading the actual logic on both sides.

## Confirmed covered (pkg's own file replaced or folded into `task-rules.ts` / the DB guard)

- pkg1's `task-overdue.ts` (`isTaskOverdue`, `sortOverdueFirst`) and `task-permissions.ts`
  (`canToggleTaskStatus`) → `feat/p1`'s `task-rules.ts` (`isTaskOverdue`,
  `compareTasksOverdueFirst`, `canCompleteTask`). The DB guard (`guard_task_status_change` in
  pkg1, `guard_task_completion` in feat/p1) covers the same open→done, done→open and
  purchase-order transitions on both sides — feat/p1's is a superset: it also disables the
  button with a specific reason (`completeBlockReason`) instead of just hiding it.
- pkg2's `profiles.address` masking (`revoke select (address)` + `get_profile_address()`) →
  feat/p2 drops `address` from `profiles` entirely and puts it in a new `staff_private` table with
  its own RLS. This is not the same mechanism patched up; it's a different, correct design — see
  "pkg2 defects, now moot" below.

## NOT covered — real work with no P-series equivalent

1. **A notification-attribution bug fix (pkg1).** `services/tasks.ts`'s `UpdateTaskInput.assignedBy`
   was required and written on every save, so editing an unrelated field (e.g. priority)
   silently overwrote who last assigned the task — corrupting the `tasks_notify_assigned`
   trigger's self-assign check (which can wrongly suppress or send a reassignment notification).
   pkg1 made `assignedBy` optional, written only when the caller is actually reassigning.
   Confirmed: `feat/p3-task-log-visibility`'s `tasks.ts` still has `assignedBy: string` required
   and unconditionally written. **This bug is live in the P-series and needs its own fix,
   independent of pkg1.**

2. **Stable fallback colour for unset `task_color` (pkg3).** pkg3's `user-colour.ts`
   (`userColour(profileId, explicitColour?)`) derives a stable hash-based colour from the profile
   id when a user hasn't picked one, so every user is visually distinguishable on the task
   calendar/list from day one. feat/p3 reads `task.assignee?.task_color` directly with no
   fallback — a user with no colour set renders with no colour at all (no border/background),
   i.e. visually identical to every other unset user. Not ported.

3. **"My Workspace" merged into Tasks (pkg3).** pkg3 removed the standalone "My Workspace" nav
   item, made My Day the default Tasks tab for every role, and moved the one real piece of
   Workspace content (the confirmation-call card) into Service → Appointments, on the reasoning
   that it's Service's business, not a personal to-do. feat/p3 still has a separate `workspace`
   nav entry and the original `WorkspacePage.tsx`. This is a deliberate UX decision pkg3 made
   that the P-series never adopted — worth a product call on whether it still should, now that
   pkg3 itself is retired and won't carry it forward.

4. **`must_change_password` on technician creation/reset (pkg2).** pkg2's
   `admin-create-technician` Edge Function sets `must_change_password: true` both when creating a
   new technician and when resetting one's password — the same forced-first-login-password-change
   pkg2/P2 built for staff. feat/p2's `admin-create-technician/index.ts` has no
   `must_change_password` reference at all: the flag only reaches staff (`admin-create-staff`,
   `admin-reset-staff-password`), not technicians. If technicians were meant to be in scope for
   P2 (pkg2 clearly treated them as in scope), this is a gap.

## pkg2 defects, now moot (no fix needed — retiring the branch retires them)

Confirmed by reading pkg2's `20261102100000_staff_profile_fields_and_huddle_attribution.sql`:

- **Ordering defect:** `revoke select (address) on public.profiles from anon, authenticated;`
  runs *before* `alter table public.profiles add column ... address text ...` in the same
  migration — the revoke targets a column that doesn't exist yet at that point in the script.
- **Inert even if reordered:** a column-level `REVOKE` doesn't shadow an existing table-level
  `GRANT SELECT` to the same role (`profiles_select_staff` / `profiles_select_by_customer` already
  grant broad row-level access) — Postgres checks table-level and column-level privileges
  independently, so this revoke would do nothing for `address` even run in the right order.

feat/p2 doesn't patch either defect — it sidesteps both by not putting `address` on `profiles` at
all (see "Confirmed covered" above). These findings apply only to pkg2's code and are retired
with the branch; no standalone fix is needed.

## Bottom line

Three of four open gaps (1, 2, 4) are real, independent pieces of work that existed on pkg1-3 and
do not exist anywhere in the P-series. Gap 3 is a product/UX decision, not a bug, and needs a call
rather than a fix. None of this blocks retiring pkg1-3 — the gaps are now tracked here instead of
living only in a branch nobody is rehearsing.
