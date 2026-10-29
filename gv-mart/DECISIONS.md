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

## 2026-10-29 "MERGE NOW" — merge executed

Owner confirmed the release complete: `origin/main` at `f81c18d`. Fetched
latest, built a fresh branch `integrate/admin-nav-restructure-v2` from
`origin/main` (not reusing the old base), merged
`feat/admin-nav-restructure-v2` in with `--no-ff`.

**Two mechanical conflicts, exactly where expected (nav.ts, AdminShell.tsx)**
— both from the release adding two new nav items (`leaveRequests`,
`expenses`) to the same array/file this branch restructured. Resolved by:

- `nav.ts`: kept the grouped structure from this branch; added
  `leaveRequests` to `serviceOps` (same roles/audience as Technicians) and
  `expenses` to `money` (same roles as the release defined: master +
  operation_admin).
- `AdminShell.tsx`: the release's per-item `leaveRequests` pending-count
  badge (inline JSX on `origin/main`) was moved into this branch's shared
  `renderNavLink()` helper, next to the existing `myDay` badge, so both
  release-added badges keep working through the new grouped-render path.

**Real finding from the diff, not assumed:** `origin/main` no longer has
the `workspace` nav item at all — a *different* package in this same
release retired it (folded into Tasks' "My Day" tab; `/admin/workspace`
now redirects to `/admin/tasks?view=myDay`, see `router.tsx`). This
branch's frozen `ORIGIN_MAIN_ROLES` test snapshot was taken at the original
rebuild point (`44f8fc1`) and still listed `workspace` — now stale. Did
**not** carry `workspace` back into the merged `nav.ts` (that would have
resurrected a feature the release deliberately removed, breaking "no role
gains or loses any item vs origin/main"). Updated the snapshot in
`nav.test.ts` to drop `workspace` and add `leaveRequests`/`expenses` with
their real roles, matching `origin/main` as it is today, not as it was at
rebuild time.

**Reachability check for every nav item the release added**, done by
reading `nav.ts` + running `nav.test.ts`'s permission-parity test, not by
assumption:
- `leaveRequests` (technician leave) — present, grouped under Service
  Operations, roles `[master, operation_admin]`, matches `origin/main`
  exactly. Reachable.
- `expenses` (Monthly Expenses) — present, grouped under Money, roles
  `[master, operation_admin]`, matches `origin/main` exactly. Reachable.
- "pending reviews" (`feat/technician-pending-reviews`), "spare handovers"
  (`feat/spare-handover-completion`), "water profile"
  (`feat/customer-water-profile`) — checked `origin/main`'s `nav.ts`
  directly: none of these three have landed as sidebar items on `main` yet
  (each still lives on its own unmerged worktree branch). Nothing to
  reach/regroup for them yet; when they do land, any that ship without a
  `group` fall into "More" automatically — that's the point of the
  fallback-group work. Nothing further to do here now.

**Expenses rename applied** (Monthly Expenses is now on `main`, so the
condition for instruction 3 is met): `nav.expenses` label changed from
"Expenses" → "Fuel & Bike Allowances" in both `en.json`/`ta.json`. No route
or path changed (`/admin/expenses` is untouched), so there was nothing to
redirect — the "keep redirects" requirement is satisfied trivially. Verified
`accounts.expensesForPeriod` (Accounts' own "Expenses" label, a different
i18n key entirely) was not touched.

**Tests**: added two new `router.test.ts` checks (`/admin/expenses` →
`ExpensesPage`, `/admin/leave-requests` → `LeaveRequestsPage`) and one
regression guard that the retired `/admin/workspace` URL still resolves —
as a redirect, not a 404.

**Full verification, re-run on the merge commit**: `tsc -b` clean; targeted
`vitest run` (nav.test.ts + router.test.ts) 24/24 passed; full `vitest run`
691 passed, 17 skipped, 0 failed (the previously-flagged pre-existing
`testCustomerGuard.test.ts` failure is gone — resolved by the release
itself, not by this merge); `oxlint` — no new warnings on any touched file;
`vite build` — clean, succeeds.

**Push**: fast-forward only, onto `origin/main` at `f81c18d`. If `main`
moved again before the push landed, the plan was: fetch, re-merge onto the
new tip, re-run the full verification above, push once more — see the
final chat report for whether that happened.

---

# Payroll-fixes decisions (incentive audit High findings H-01/H-02/H-03, 2026-10-29)

Unrelated to the admin-nav-restructure work logged above — this section is a
**separate** work stream, branch `feat/payroll-fixes`, worktree
`GV_mart/_local_only/worktrees/payroll-fixes`, created fresh from `origin/main` at
`db1638e`. Scope: the 3 HIGH findings from the incentive audit only, per the
owner's own instruction — nothing else from the audit was touched.

## D1 — H-01 link column shape

The audit's suggested fix mentioned populating the existing (unused) `ref_id`
column. Used a dedicated `expenses.salary_id uuid references salaries(id)` column
instead, additive and nullable. `ref_id` already means different things for other
`expenses` categories in this codebase (no FK, no documented single meaning) —
overloading it for salary specifically would have made it less clear, not more.
`salary_id` is self-describing and lets the unique index be a straightforward
partial index on one column.

## D2 — Idempotency key differs by path

Technician path keys off `salary_id` (one `salaries` row -> at most one posted
expense, ever, while non-voided). Non-technician staff path has no `salaries` row
at all, so it keys off `(staff_id, calendar month)` instead. Both are partial
unique indexes with `voided_at is null` in the predicate (see D4) so a corrected
re-log after a reopen/void is never blocked by the row it replaced.

## D3 — One RPC for both paths

`log_salary_to_accounts(p_org_id, p_staff_id, p_amount, p_date, p_note,
p_salary_id)` — `p_salary_id` null distinguishes the staff path from the technician
path, rather than two separate RPCs. Keeps one master-only ACL surface and one
idempotency-handling code path (unique-violation caught, reported as a clean
no-op) instead of two near-duplicates.

## D4 — Independent-review fix: voided_at must be excluded from expenses_salary_once_idx

An independent reviewer agent caught, before apply, that the technician-path
unique index (`expenses_salary_once_idx`) did NOT exclude voided rows the way the
staff-month index did. Combined with `reopen_salary_posting` voiding the old
expense but never clearing its `salary_id`, this would have permanently blocked
re-logging a corrected salary after every reopen — the entire point of the H-03
fix. Fixed by adding `and voided_at is null` to that index's predicate (matching
the staff-month index) and to the unique-violation lookup inside
`log_salary_to_accounts`. A regression test (test2's T8/T8b/T8c) now covers
exactly this path. Rehearsed again after the fix — all green.

## D5 — Void convention for a plain `expenses` row

No void/reversal convention exists for `expenses` in this codebase today (only
`installation_incentive_credits` has one, for a different table).
`expenses.amount` also has `check (amount >= 0)`, ruling out a reversing negative
entry without also leaving the original figure visibly overstated to any report
that doesn't know to net the two against each other. Chose the smallest change:
`voided_at`/`voided_by`/`void_reason` flag columns, mirroring
`installation_incentive_credits`' shape in spirit. Every report function that
sums `expenses.amount` (`report_expenses_salary_by_staff`,
`report_expenses_year_over_year`, `report_pnl`, `report_kpi_tiles` — confirmed via
grep to be the only 4 functions that read `public.expenses` at all) now filters
`voided_at is null`, so a voided salary stops counting in every money total, not
just the ones specific to this feature.

## D6 — Audit table FK semantics (independent-review fix, non-blocking but applied)

`salary_reopen_audit.salary_id`/`technician_id` use `on delete restrict`, not
`cascade` — an append-only audit trail must not vanish because something it
references was later deleted. `org_id` keeps `cascade`, matching every other
org-scoped FK in this schema (org deletion already cascades everything; there is
nothing to restrict against). Confirmed via grep that no code path in this
codebase ever hard-deletes a `salaries` or `technicians` row, so this changes no
existing behaviour.

## D7 — H-02 "referral type" and scope of the capture-layer fix

The task decided a referral bonus may be earned "at most once per (customer,
technician, referral type)". This codebase has exactly ONE referral bonus
mechanism (`finder_credit`), so `leads.referral_type` is a new text column with a
single value today, `'finder_credit'` — a column rather than a hard-coded literal
in the index purely so a future second referral-bonus type could get its own
independent one-per-pair slot without a schema change.

**The real fix is at the metric layer**, not the capture layer:
`technician_finder_conversions()` now counts `distinct st.customer_id` instead of
`distinct v.ticket_id`. This closes the double-count regardless of which function
created the duplicate `leads` row, and regardless of `leads.source` — it is the
one function this incentive's money actually reads.

The capture-layer DB guard (partial unique index on
`leads(customer_id, owner_id, referral_type) where source='referral' and
owner_id is not null`, enforced via a `BEFORE INSERT` trigger) was deliberately
implemented as a trigger that strips `NEW.owner_id` to null on a duplicate,
**not** by skipping the insert and **not** by editing the 4 functions that use
this `source='referral'` pattern (`create_sale`, `sell_amc_plan`, `renew_amc_plan`,
`_create_complaint_ticket_internal`):
- Skipping the insert was the first design, but `lead_activities.lead_id uuid not
  null` would have raised inside all 4 callers on every duplicate, turning a
  silent-tolerance requirement into an outright sale-blocking bug. Nulling
  `owner_id` instead lets the row insert succeed normally — every downstream
  `returning id into v_lead_id` gets a real id — while the row is simply no
  longer attributed to that technician, exactly how these functions already treat
  an unknown/invalid `p_referred_by_technician_id`.
- Editing all 4 callers (hundreds of lines each, many historical revisions) to add
  matching `ON CONFLICT` clauses was rejected as a far larger, far riskier diff for
  no improvement over the trigger, and a plain unique index without that handling
  would have made a legitimate second sale (e.g. an AMC renewed a year later) throw
  an unhandled `unique_violation` and abort the whole sale — a regression.

## D8 — sell_amc_plan_onsite is out of scope for the capture-layer guard

Its CURRENT live body (`20261016100000_amc_cancel_visit_scheduling_overlap.sql`)
no longer takes an optional referring-technician id at all — every on-site AMC
sale attributes to the acting technician under `source='field'`, a different,
mandatory mechanism, not the optional `source='referral'` pattern the other 4
functions use. Left untouched. The metric-layer fix (D7) still protects its money
either way, since `technician_finder_conversions()` doesn't filter by
`leads.source`.

## D9 — Reporting functions redefined are byte-faithful except the one stated change

`compute_salary`, `report_expenses_salary_by_staff`, `report_expenses_year_over_year`,
`report_pnl`, `report_kpi_tiles` were each re-fetched live via
`_local_only/reports/run_rehearsal.mjs` (`_local_only/reports/payroll_fixes/
backup_before.sql.out.txt`) before being edited, confirming the worktree's own
source files were already byte-identical to the live definitions, and the
independent reviewer separately diffed each redefinition against that same
live-fetched body.

## Status at hand-off

All 3 migrations: rehearsed (pass), independently reviewed (1 blocking issue found
and fixed, re-rehearsed pass), DRYRUN OK pre-check passed for migration 1. **Live
apply was blocked by Claude Code's own permission-gate classifier
("Production Deploy") before any migration touched the live database** — see the
final report for the exact denial and what is needed to proceed. Nothing has been
applied live. Frontend code, tests, lint, and build are complete and passing in
this worktree, but the branch is deliberately NOT pushed to origin/main: the new
frontend code calls `log_salary_to_accounts`/`reopen_salary_posting`, which do not
exist in production yet — pushing (and deploying) before the migrations are
applied would break those two buttons live.
