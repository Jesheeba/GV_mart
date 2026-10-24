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

## Ported into the P-series (2026-10-24) — gaps that needed porting before pkg1-3 are abandoned

1. **A notification-attribution bug fix (pkg1) → `feat/p3-task-log-visibility` (`7bb89b5`).**
   `services/tasks.ts`'s `UpdateTaskInput.assignedBy` was required and written on every save, so
   editing an unrelated field (e.g. priority) silently overwrote who last assigned the task. This
   is not only an attribution bug: `tasks_update_assign` (20261101100000) grants UPDATE to
   `assignee_id = auth.uid() or assigned_by = auth.uid()`, so the overwrite moved that update
   right from the task's original assigner to whoever last edited it. Made `assignedBy` optional,
   written only on an actual reassignment; `TaskDetailDialog` now omits the key entirely rather
   than resending a (possibly stale or null) current value. Added `tasks.test.ts` pinning the
   exact update payload, and extended `task_completion_rule.test.sql`: an unrelated edit by the
   assignee leaves `assigned_by` untouched, and the original assigner can still update the row
   afterwards.

2. **`must_change_password` on technician creation/reset (pkg2) → `feat/p2-staff-profile-huddle`
   (`baafe88`).** pkg2's `admin-create-technician` Edge Function set `must_change_password: true`
   both when creating a new technician and when resetting one's password — the same
   forced-first-login-password-change P2 built for staff. feat/p2's mechanism (`profile_password_markers`
   + `arm_forced_password_change` + `complete_forced_password_change`, a stronger design than
   pkg2's own boolean-only flag — see "pkg2 defects, now moot" below) is role-agnostic, so only the
   wiring was missing: `"create"` now sets the flag in the same profile insert (after the password
   exists, same ordering as staff), `"reset_password"` now calls `arm_forced_password_change` after
   the password update. Added a test block in `p2_staff_profile_and_huddle.test.sql` proving both
   paths for a technician profile.

3. **Stable fallback colour for unset `task_color` (pkg3) → `feat/p3-task-log-visibility`
   (`047c102`).** pkg3's `user-colour.ts` (`userColour(profileId, explicitColour?)`) derives a
   stable hash-based colour from the profile id when a user hasn't picked one, so every user is
   visually distinguishable on the task calendar/list from day one. feat/p3 was reading
   `task.assignee?.task_color` directly with no fallback. Ported the utility and its test verbatim
   (only the doc comment's migration-column reference corrected to `task_color`, feat/p2's actual
   name for it) and wired it into both read sites (`TaskCalendar.tsx`, `TasksPage.tsx`). Cosmetic,
   no schema change.

## Left alone — a product decision, not a gap (open question for the owner)

**"My Workspace" merged into Tasks (pkg3).** pkg3 removed the standalone "My Workspace" nav item,
made My Day the default Tasks tab for every role, and moved the one real piece of Workspace
content (the confirmation-call card) into Service → Appointments, reasoning that it's Service's
business, not a personal to-do. feat/p3 still has a separate `workspace` nav entry and the
original `WorkspacePage.tsx`. This was **not** ported: it's a deliberate UX call, not a bug, and
pkg3 retiring doesn't carry it forward automatically. Open question for the owner: should the
P-series adopt pkg3's merge, keep Workspace standalone, or something else? No code changed here.

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

All three real gaps (the assignedBy permission bug, must_change_password for technicians, the
colour fallback) are now ported into the P-series, each as its own commit, with tests. The My
Workspace merge is deliberately left as an open product question, not ported — see above. pkg1-3
are fully retired: nothing that mattered is left stranded on a branch nobody is rehearsing.
