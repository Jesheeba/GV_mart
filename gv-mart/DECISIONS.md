# DECISIONS.md — admin nav/feature audit rebuild (2026-10-28)

Log of decisions made while rebuilding `feat/admin-nav-restructure` into
`feat/admin-nav-restructure-v2` per the owner's instruction. Each entry
maps to a numbered instruction from that message.

## 1) Base check

`git merge-base --is-ancestor origin/main feat/admin-nav-restructure` → **not an
ancestor**. `git log --oneline origin/main..feat/admin-nav-restructure` showed
8 commits, 7 of which were not mine — the branch had been cut from
`ui-ux-improvements` (tip `4ee1a95`, a merge of `feat/monthly-expenses`), not
from `origin/main`. Those 7 commits belong to the Monthly Expenses feature
(bike/fuel allowances, technician KM log, incentive compute changes) and are
someone else's unmerged work-in-progress, not mine.

**Rebuilt from `origin/main` (44f8fc1)** as `feat/admin-nav-restructure-v2`,
in a fresh worktree, with only my own changes re-applied as new commits (not
cherry-picked — see below for why).

**Finding that affects scope:** `origin/main` does not have the Monthly
Expenses feature *at all* — no `ExpensesPage`, no `nav.expenses` sidebar
entry, no `/admin/expenses` route. It only exists on `ui-ux-improvements`
(merged in via `feat/monthly-expenses`, not yet on `main`). This means:

- The previous branch's commit couldn't be cleanly cherry-picked onto
  `origin/main` anyway (the nav.ts hunk that renamed `nav.expenses` has no
  context to apply against — the entry doesn't exist yet).
- **Instruction (5)(b) "Fuel & Bike Allowances rename" is deferred, not
  included in this rebuild.** There's nothing on `origin/main` to rename yet.
  The rename text is ready to apply the moment Monthly Expenses lands on
  `main` — see `PHASE2_PROPOSALS.md`.

All other touched files (`AccountsPage.tsx`, `HrPage.tsx`, `ReportsPage.tsx`,
`AdminShell.tsx`, `ComplaintsPage.tsx`, `TicketsListPage.tsx`,
`PnlReportTab.tsx`, `router.tsx`'s admin-complaints line) are byte-identical
between `origin/main` and the old branch's base, confirmed with
`git diff origin/main 4ee1a95 -- <path>` returning nothing for each. So the
sidebar regroup, HR merge, and P&L move apply to `origin/main` exactly as
designed the first time — only the Expenses-feature-dependent piece doesn't.

## 2) Complaints restored

The previous branch's removal of the Complaints tab is **not carried into
v2 at all** — v2 is built from `origin/main`, which already has Complaints
untouched. `nav.ts`, `router.tsx`, and `ComplaintsPage.tsx` are exactly as
on `origin/main`; Complaints simply picked up a `group: "serviceOps"` tag
like every other item, same as it would have regardless.

The "retire Complaints" idea (it's a pure duplicate of Service's own ticket
list — same `service_tickets` table, same overdue predicate, zero unique
write actions — verified by code reading, not assumption) is recorded as a
proposal only, in `PHASE2_PROPOSALS.md`. Not acted on.

The one piece kept from that investigation: a **Repeat Complaint quick-filter
chip added to Service's ticket list** (commit `e8d3b67`). This is additive
and harmless — it reuses a repeat-customer set Service already computed for
row badges (`useRepeatComplaintCustomers`), exposed as a new selectable
filter. It changes nothing about Complaints and removes nothing.

## 3) Campaigns

No send path was added or wired. The existing "no send integration" note
(`campaigns.noSendIntegrationNote`) was a quiet grey caption under the
create button — easy to miss, so a master could believe a logged campaign
was actually sent. Reworded to lead with "Log only: nothing is sent to
customers from here" and restyled as a warning-toned banner with an icon,
moved above the fold (commit `a1c5496`).

## 4) Tests

The one failing test, `src/lib/testCustomerGuard.test.ts` ("every
report/KPI/count function is decided in the manifest"), **fails identically
on pristine `origin/main`** — verified by checking out `origin/main` into a
throwaway worktree and running that file alone before any of my changes
were applied. It flags `customer_filter_counts` (added in migration
`20261024170000`, unrelated to anything in this change) as undecided in
`src/lib/testCustomerGuard.ts`'s manifest. Not caused by, and not fixed by,
this work — flagging for whoever owns that migration.

New tests added: `src/app/admin/nav.test.ts` (sidebar visibility per role —
master sees every item, operation_admin/sales_admin see role-scoped
subsets, technician/customer see nothing because `ADMIN_NAV.roles` never
lists those two roles) and `src/router.test.ts` (route-table check that
`/admin/complaints` still resolves to `ComplaintsPage`, not a 404 or a
redirect, using `matchRoutes` against the real exported `router` — no
rendering, no jsdom, consistent with this repo's existing node-environment,
logic-only test style). There is no separate "old P&L route" or "old
Expenses route" to test: P&L was always a `Tabs` value inside `/admin/reports`,
never its own URL, and the Expenses route doesn't exist on `origin/main` at
all (see above) — both are noted here rather than silently skipped.

## 5) Commit split

Four commits as instructed, each independently droppable without touching
the others:

- `a1c5496` — sidebar regroup + labels + Campaigns notice
- `9011939` — HR Salary/Staff Salary toggle
- `8ef16d4` — P&L move into Accounts
- `e8d3b67` — Repeat Complaint chip on Service (additive, not one of the
  original four, added per instruction 2's "keep it if harmless")

(b) Fuel & Bike Allowances rename is not a commit here — see §1.

## 6) Merge gating

Not pushed. See the final report for the exact READY TO MERGE commands and
the two conditions this is waiting on.
