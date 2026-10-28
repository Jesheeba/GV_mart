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
`/admin/complaints`, `/admin/accounts`, `/admin/reports` and `/admin/hr`
still resolve to their pages). That test can't actually import `router.tsx`
and call `matchRoutes` against it — `createBrowserRouter` runs at module
load and touches `document`, which doesn't exist in this repo's
node-environment vitest setup (no jsdom/happy-dom dependency here, and
adding one felt like scope creep for a nav change), and `src` isn't typed
for Node builtins either (no `"node"` in `tsconfig.app.json`'s `types`, so
`node:fs` wasn't an option). Settled on a text-match check against
`router.tsx`'s source via Vite's `?raw` import instead — a regression guard
on the route *shape*, not a renderer. There is no separate "old P&L route"
or "old Expenses route" to test: P&L was always a `Tabs` value inside
`/admin/reports`, never its own URL, and the Expenses route doesn't exist
on `origin/main` at all (see above) — both are noted in the test file
rather than silently skipped.

## 2026-10-29 update — merge gate change + fallback "More" group

Per owner instruction, received after the report above:

**Merge gate narrowed.** The `feat/accounts-outstanding-followups` check is
dropped — that branch is still in planning and its tip is currently
identical to `origin/main`'s (0 commits ahead), which reads as "hasn't
started," not "merged and cleaned up." Rather than resolve that ambiguity,
the owner said to ignore it; it'll rebase onto `main` itself. **The only
remaining gate is `release_log.md` showing the release's code phase
finished** (all packages merged to `origin/main`). As of this update that
log is still mid-Phase-2 (2 of 3 independent-reviewer results pending) —
not finished.

**Fallback "More" group added**, because the release about to land on
`main` adds several nav items (technician leave, pending reviews, spare
handovers, monthly expenses, water profile, possibly more) that this
branch's grouping has no knowledge of yet. Any `ADMIN_NAV` item that omits
`group` now renders under a visible "More" section at the bottom of the
sidebar instead of silently disappearing — implemented as a new pure
function, `groupNavSections()` in `nav.ts`, used by `AdminShell.tsx`. Items
with a real group are unaffected; `AdminNavGroup` (the explicit section
names) deliberately does NOT include `"more"` as a settable value, so a
future edit can't accidentally type `group: "more"` instead of just
omitting `group` — the fallback only ever happens by omission, never by
choice.

Added test coverage: `nav.test.ts` now has a `"fallback 'More' group"`
describe block (a fake unmapped item lands in "More" for a role that can
see it, is absent for a role that can't, "More" always sorts last, and an
item with a real `group` never falls into "More" even if a fake one is
added alongside it) and a `"permission parity vs origin/main"` describe
block (a frozen `{key: roles[]}` snapshot taken from `origin/main`'s
`nav.ts` at rebuild time, asserting every role's visible-key set today
exactly equals that snapshot — catches any future edit that accidentally
grants or revokes access to an item).

## 5) Commit split

Four commits as instructed, each independently droppable without touching
the others:

- `a1c5496` — sidebar regroup + labels + Campaigns notice
- `9011939` — HR Salary/Staff Salary toggle
- `8ef16d4` — P&L move into Accounts
- `e8d3b67` — Repeat Complaint chip on Service (additive, not one of the
  original four, added per instruction 2's "keep it if harmless")
- (2026-10-29) one more commit — fallback "More" group + its tests (not one
  of the original four either; added per the 2026-10-29 instruction, see
  above)

(b) Fuel & Bike Allowances rename is not a commit here — see §1 and
instruction 3 of the 2026-10-29 update: apply it only once Monthly
Expenses is itself on `main`.

## 6) Merge gating (updated 2026-10-29)

Not pushed. **Single remaining gate: `release_log.md` shows the release's
code phase finished** (all packages merged to `origin/main`). The
`feat/accounts-outstanding-followups` condition from the original report
is dropped per instruction. Owner will say "MERGE NOW" in-session once the
release log shows that; until then, stop after the fallback-group work
above. See the latest chat report for the exact merge commands to run once
that's true.
