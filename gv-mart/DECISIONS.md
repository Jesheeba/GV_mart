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
and fixed, re-rehearsed pass), DRYRUN OK pre-check passed for all three. **Applied
live 2026-10-29** (09:31:32 / 09:31:53 / 09:32:10 UTC respectively, after the owner
added the required permission rule), verified post-apply via the approved template's
own checks, then re-verified end-to-end via a live RLS-impersonation pass on
throwaway TEST data (6 scenarios, 15 sub-checks, all green —
`_local_only/reports/payroll_fixes/live_verify_PASS.out.txt`), cleaned up (minus an
empty `__TEST_` org shell — see D10 below), and pushed to `origin/main` as a genuine
fast-forward (`316c182..7d04c00`).

## D10 — purge_test_organisation() cannot delete a test org's expense_categories rows

Found during the live-verification cleanup, unrelated to this task's own 3
findings: the project's shared `purge_test_organisation(uuid)` function (added
2026-10-11) refuses with "expense_categories: a system category cannot be
deleted" when it tries to cascade-delete an org, because a LATER migration
(`20261115110000`, expense categories) added a BEFORE DELETE guard on
`expense_categories` that `purge_test_organisation()` was never updated to get
past. Not fixed here (out of scope) — flagged for whoever owns test-data hygiene
next. Worked around for this task's own cleanup by deleting every other table
directly (same `app.audit_purge_ok` technique that function itself uses for
`audit_log`) and leaving the org + its auto-seeded, contentless category rows in
place, consistent with this project's existing "leftover `__TEST_` org" norm.

## D11 — follow-up: every expenses reader must exclude voided rows, not just the 4 SQL functions

A second pass (same day) found 4 MORE places that sum/list `expenses.amount` and
did NOT exclude `voided_at` — all client-side TypeScript, none requiring a new
migration (the SQL side was already complete):
- `getExpensesList()` (`src/services/reports.ts`) — the LIVE function behind the
  Accounts page's expense list, its "Under Category" per-category totals, and
  its category filter (all three are computed client-side FROM this list's
  result). This was a real, live, user-facing gap: a voided salary expense
  would still have shown up in the Accounts screen and counted into its
  category total. Fixed with the same `.is("voided_at", null)` every SQL
  function already applies.
- `getPnlReportLegacy()`, `getSalarySpendByStaffLegacy()`,
  `getExpensesYearOverYearLegacy()` — all three explicitly `@deprecated`, kept
  only so `reports.parity.test.ts` can assert the new RPC-based reports produce
  identical numbers to the old browser-side aggregation. Not reachable from any
  live page (confirmed: grepped every `.tsx` under `src/app/` for each name —
  zero hits outside `reports.ts`/`useReports.ts`/the parity test itself), but
  left unfixed they would have made that parity test start failing the moment
  any org ever has a voided expense — fixed to keep genuinely proving parity,
  not accidentally proving a false equivalence.
- Confirmed NOT in scope / correctly unaffected: `createExpense()` (insert
  only), `delete_expense_category()` (an existence check for referential
  integrity, not a money total — a category that was ever used, voided or not,
  should still refuse deletion), `create_bill_entry()`'s 5 historical
  redefinitions (insert only, never reads), and the Monthly-Expenses-feature
  `ExpensesPage.tsx` (technician/admin) — that screen is `expense_claims` +
  vehicle/allowance tables, a completely different domain from the `expenses`
  accounting ledger table this finding is about, confirmed via grep (zero
  `"expenses"` table references in either file).

Proven correct via a rehearsal (not a migration — nothing new to apply) on
throwaway `__TEST_` data: baseline → post a salary → reopen (void) → re-post,
checking `report_pnl`, `report_kpi_tiles`, `report_expenses_salary_by_staff`,
`report_expenses_year_over_year`, and a raw SQL query identical to
`getExpensesList`'s own filter, all in the same pass. All 16 checks passed —
`_local_only/reports/payroll_fixes/rehearsal_voided_proof_PASS.out.txt`.

`src/types/database.ts`'s hand-patched `expenses` Row/Insert/Update (the
established convention in this file for a post-codegen column — see the
existing `category_id` precedent right above it) gained `salary_id`/
`voided_at`/`voided_by`/`void_reason`, so `getExpensesList`'s new
`.is("voided_at", null)` typechecks without a local cast.

---

# payroll-fixes2 (2026-10-29) — new findings, incident investigation, F-01/F-02/F-05

Separate work stream, branch `feat/payroll-fixes2`, worktree
`GV_mart\_local_only\worktrees\payroll-fixes2`, fresh from `origin/main` at
`d2d28f7`. Builds on the H-01/H-02/H-03 work above and a separate
`incentive-map` connection-map audit another agent ran.

## Standing rule (owner-mandated, applies to all remaining work in this task)

Every rehearsal or live-verification step that calls a MUTATING function must be
proven rolled back by an INDEPENDENT read-only re-query of the affected real
tables — row counts AND a content fingerprint (md5/sha256 digest of the actual
rows) — taken BEFORE and AFTER the call. The before/after must be byte-identical.
If they differ, stop immediately and report rather than continuing or
self-correcting.

## Incident: connection-map audit's "Part 3 preview" posted real ₹0 salaries to the real org

Investigated per owner's explicit request (items 1-4 of the follow-up task). Full
detail in the chat handback; summary here for the written record:

- The `incentive-map` audit's own report (`connection_map.md` §3) describes
  running `compute_salary` "for real, live, on the real technicians" and asserts
  this was "confirmed rolled back." The real database shows otherwise: 2 real
  `salaries` rows (technicians `48a3dc54…`/`cee294f0…`, period 2026-10) were
  INSERTED and then LOCKED (via `log_salary_to_accounts`) at 10:17:50/
  10:18:00-10:18:06 UTC on 2026-10-29, each with a real `expenses` row
  (category='salary', amount=0.00) still live and un-voided as of this
  investigation.
- A third, pre-existing real row (technician `e4b0986f…`, salary id
  `cadac3d9-db7a-4458-a071-7a0c126b3360`) was recomputed in place at the same
  time, net going from **0.00** (its value since 2026-10-06, confirmed via
  `audit_log` — this IS the same row the original `incentive_audit.md` saw as
  "exactly one salaries row at net 0.00") to **-39.30** (real attendance-driven
  late deduction, no base tier configured to offset it). Not locked, no expense
  created for it — left untouched per owner's instruction; will self-correct
  once F-01 (floor-at-zero) ships and it's recomputed.
- No double-posting: each locked row has exactly one, never-voided expense.
  Exact amounts posted: ₹0.00 and ₹0.00 — zero real money moved.
- Root cause (best determination from available evidence — the actual wrapper
  SQL file was NOT found saved anywhere in `_local_only/reports/incentive_map/`,
  only its two output CSVs and the markdown report, so the literal script could
  not be read line-by-line as asked): the hard rule this project's rehearsal
  convention exists specifically to enforce is ONE DO block per script, ending
  in an unconditional `RAISE EXCEPTION`, so a mid-script failure OR a deliberate
  final raise rolls back everything atomically. The evidence is consistent with
  that convention having been violated for the October leg of that script
  specifically: `compute_salary`/`log_salary_to_accounts` calls for the 2
  technicians committed independently (each got its own real, persisted
  `audit_log` entry with its own timestamp seconds apart — 10:17:50, then
  10:18:00, then 10:18:06 — rather than one atomic block), while the September
  leg of the SAME investigation left zero trace in `salaries` at all, meaning
  THAT leg genuinely rolled back. Two different pieces of the same investigation
  behaving differently is the strongest evidence available that the script was
  not structured as the required single atomic block throughout — most likely
  separate top-level statements/DO blocks per period or per technician, where
  only the final one's rollback was unconditional and the earlier ones had
  already committed by the time it ran. This is a determination from indirect
  evidence (timestamps + the asymmetry between what persisted and what didn't),
  not a confirmed line-by-line reading of the script, because that script is not
  available to read.
- Sweep for any OTHER leak this week (mine or others'): read-only, see
  `_local_only/reports/payroll_fixes2/step3_leak_sweep.sql.out.txt`. Exactly 3
  `__TEST_`-named orgs exist; 2 predate this entire incident by 11-17 days
  (`2026-10-12`, `2026-10-28`, unrelated prior work) and 1 is my own documented
  `__TEST_live_verify_payroll_fixes` shell from the FIRST payroll-fixes round
  (created 09:34 UTC today, expected per that round's own DECISIONS.md D10 —
  purge_test_organisation()'s pre-existing gap, not a new leak). Zero
  test-looking rows found in tasks/expenses/incentives_earned/rewards/
  notifications/leads for the real org. Zero notifications or whatsapp_outbox
  rows created in the 10:15+ UTC window (and neither `log_salary_to_accounts`
  nor `reopen_salary_posting` nor `compute_salary` ever write to either table —
  confirmed by reading their bodies, not just the empty query result). Row-count
  comparison against my own first-round baseline
  (`_local_only/reports/payroll_fixes/backup_before_counts.sql.out.txt`) shows
  every single delta is fully explained by this one incident: `salaries` +2 rows
  / -39.30 net, `expenses` +2 rows / +0.00 sum — nothing else moved.

## Item 1 (reopen the 2 erroneous rows) — skipped per owner decision

Owner decided to skip reopening the 2 real ₹0 locked salary rows — the gate
blocking it ("Modify Shared Resources") is a separate safety gate, not a
missing permission rule, and doesn't clear even with the run_rehearsal.mjs
rule the owner had already added. Left exactly as found: 2 rows locked, 2
real ₹0 expenses un-voided, no money impact. The exact command the owner can
run themselves whenever ready is in the final chat report (same one blocked
here, nothing has changed about it).

## F-01/F-02/F-05 — fixes shipped

- F-01 (floor at zero + visible shortfall) and F-02 (deactivated-technician
  guard): one migration, `20261118100000_compute_salary_floor_and_inactive_guard.sql`
  — adds `salaries.shortfall_amount`, floors `net` at
  `greatest(raw_net, 0)`, records `shortfall_amount = greatest(-raw_net, 0)`,
  and refuses a technician that is `not ... is_active` with the same
  raised-exception shape as the existing "not found" case (mirrors
  `compute_incentives`'s own `is_active` loop filter exactly). Proven
  byte-identical for a currently-positive-net technician, and correctly
  floored+recorded for a would-be-negative one, in the same rehearsal run
  (`rehearsal1_PASS.out.txt`).
- F-05 (referral validated-list-or-warning): one migration,
  `20261118100001_renew_amc_referral_match_signal.sql`. Audited all 5 capture
  points (see the migration's own header) — 3 already use a real `<select>`
  bound to the technicians list (`create_sale`/`NewSalePage.tsx`,
  `sell_amc_plan`/`SellAmcPanel.tsx`, `create_complaint_ticket`/
  `NewComplaintPage.tsx`), nothing to fix there; `sell_amc_plan_onsite`'s
  current body no longer takes an optional referrer at all, not an instance
  of this pattern; `renew_amc_plan` (customer self-service, free-typed name —
  a customer only knows a name, not an id) was the one genuine gap, now
  returns `referral_matched` (null/true/false) so the frontend
  (`AmcBookingPanel.tsx`) can warn on a miss instead of staying silent.
  **Bonus fix found while rehearsing this migration**: the pre-existing
  `select count(*), min(t.id) into ...` raised `function min(uuid) does not
  exist` on this Postgres version — ANY renewal where a customer typed ANY
  referring-technician name (match or not) crashed the ENTIRE renewal, not
  just the referral part. Fixed in the same migration (plain count + a
  separate lookup only when count=1).

## Apply status

- `20261118100001_renew_amc_referral_match_signal.sql` (F-05) — **applied
  live** 2026-10-29 13:19:10 UTC (by this agent), verified, registered.
- `20261118100000_compute_salary_floor_and_inactive_guard.sql` (F-01/F-02) —
  blocked for this agent twice by the same "Production Deploy" permission-
  gate classifier (not retried, not worked around either time — the owner
  confirmed a chat-level authorization alone does not clear a Claude-Code-
  level classifier). **Applied live by the owner themselves**, running the
  prepared `apply1_live.sql` command directly, confirmed registered in
  `supabase_migrations.schema_migrations`. Post-apply, this agent
  independently re-verified: `compute_salary`'s live body contains the exact
  reviewed floor/shortfall/is_active logic, is not anon-executable,
  `salaries.shortfall_amount` exists, and a full real-data row-count/sum
  comparison against every prior snapshot this session (`salaries` n=3
  sum_net=-39.30, `expenses(salary)` n=2 sum=0.00, `expenses(all)` n=3
  sum=4500.00, `incentives_earned`/`rewards`/`leads_referral` all 0) is
  byte-identical before and after — confirming the apply changed ONLY the
  function definition and added ONLY the new column, touching no existing
  row's data. A rolled-back TEST-data rehearsal against the now-live function
  proved F-01 (positive-net unaffected; would-be-negative floored to 0 with
  shortfall_amount=10.00 recorded) and F-02 (deactivated technician refused)
  both behave exactly as designed, while a before/after fingerprint of the
  3 real technicians' own `salaries` rows (net/shortfall_amount/locked_at)
  proved they were never touched by any of this verification work.

# manual-link: master-only Google account linking stopgap (2026-10-29)

Worktree `GV_mart\_local_only\worktrees\manual-link`, branch `manual-link` off `origin/main` (ed83c46). Reports in `GV_mart\_local_only\reports\manual_link\`.

## 1) Trust model, vs. the old revoked RPC

The old `link_customer_google_account(p_mobile text)` (20260729130000, revoked 20261021100000) let the SIGNED-IN CALLER type a mobile number and get linked to whichever customer owned it — anyone who knew (or guessed) a customer's mobile could claim their record. That RPC's grant stays revoked; nothing in this change touches it.

This feature flips who is trusted: the MASTER, already on one specific customer's detail page, types the Google email the customer told them they used. The RPC (`admin_link_customer_google_account`) re-derives everything else server-side — it never trusts a client-supplied customer-id-to-auth-id mapping beyond "this customer" and "this email", and re-checks master role + org ownership itself (never relies on the UI gate alone).

## 2) Match by Google identity, not by `auth.users.email`

Matches against `auth.identities` where `provider = 'google'`, not `auth.users.email` — the identities row is what Supabase actually recorded at the OAuth handshake; `auth.users.email` could in principle be set some other way. Email is `lower(trim(...))` on both sides (closes case/whitespace tricks). Exactly one match is required — zero means `no_matching_signin`, more than one means `ambiguous_signin` (refuses rather than silently picking one).

## 3) Why "any existing profile" blocks the link

Any auth user that already has a `profiles` row — customer, staff, technician, whoever — is refused (`signin_already_linked`). This is what stops a master from accidentally linking a staff member's or technician's own Google sign-in to a customer record: staff/technicians always have a profile already, so they can never match.

## 4) Unlink deletes the profile, not just the pointer

"Unlink" clears `customers.primary_profile_id` AND deletes the `profiles` row (not just the pointer) — otherwise the freed auth user would still own an orphaned profile and could never be relinked (the link RPC explicitly checks for and refuses an existing profile). Requires a non-empty reason; both actions write to the existing `audit_log` table (reused, no new audit table) via the standard `(org_id, actor_id, action, table_name, row_id, before, after)` shape already enforced append-only by `20261011110000_audit_log_append_only.sql`.

## 5) Concurrency

Both functions `select ... for update` the target `customers` row first, serializing concurrent calls on the same customer. The link path also wraps its `insert into profiles` in an exception block catching `unique_violation`, in case a *different* customer's concurrent call matched the same Google identity first.

## 6) UI placement

A master-only tab ("Google Account") on `CustomerDetailPage`, gated the same way the existing delete button is (`profile?.role === "master"`) — not visible to `operation_admin`/`sales_admin`. The customer-facing "One more step" screen (`GoogleLinkAccountCard.tsx`) is untouched.

## 7) BLOCKED — rehearsal/apply tooling not found

The task specified database changes go only through `run_rehearsal.mjs` (Management API runner), with a specific sha256 to verify first. Searched this worktree and the sibling worktrees most likely to hold it (`GV_mart_grants`, `GV_mart_linkfix`, `GV_mart_secfix`, `customer-otp-link`) — **no `run_rehearsal.mjs` exists anywhere found**. I will not fabricate a hash check against a file I can't locate, and will not improvise a different live-apply path for a security-sensitive, account-linking migration without the tool the instructions named. Flagging this rather than guessing — see final report to the owner for what's needed to unblock (either point me to the runner's actual location, or confirm I should build one to the project's existing apply/rehearsal script conventions in `supabase/ops/`).

Local build/test gate for the code already run clean: `tsc -b`, `oxlint`, `vitest run` (756 passed, 17 skipped), `npm run build` — all exit 0, logs in the reports dir above. Migration, RPC, UI, and EN/TA strings are written and committed to this branch but **NOT applied to any database, rehearsed or otherwise** — no DB access has happened at all for this task.

## 8) Independent security review — findings and resolution

Fresh-context agent reviewed the final design against: non-master/anon access, master-typo blast radius, race conditions, linking a staff/technician's own sign-in, email case/whitespace/homoglyph tricks, org-scoping, `search_path`/schema-qualification, and the project's known default-privileges-auto-grant-to-anon issue.

**Verdict: no unresolved High findings.** Confirmed clean: non-master/anon access (blocked at grants AND in-function `is_master()` check), org-scoping (airtight, `for update`-locked), race conditions (closed by the row lock + `profiles` PK + explicit `unique_violation` catch), no dynamic SQL, full `search_path=''` schema-qualification discipline, and the default-privileges issue (already fixed project-wide, this migration's explicit revoke-then-grant is consistent with it).

Two Medium findings, both resolved before rehearsal:

- **M1 — cross-org email oracle.** `auth.identities` has no `org_id` (it's shared across every tenant), so the lookup can't be org-scoped, and the distinguishable `no_matching_signin` / `ambiguous_signin` / `signin_already_linked` outcomes let a master learn whether an arbitrary email has signed in via Google *somewhere* in the system (not which org). **Resolved: accepted as a documented, deliberate trust boundary**, not code-changed — collapsing the messages into one generic error would contradict this task's own requirement for a clear, specific refusal message to the master ("since the master is trusted"), for a leak (an email's bare existence, not an org's customer list) that isn't sensitive in the way the alternative fix's cost would be. Comment added directly above the lookup in the migration explaining this explicitly, so a future reviewer doesn't have to re-derive it.
- **M2 — no confirmation step before link/unlink commits.** Neither action in `GoogleAccountLinkPanel.tsx` had a confirm step, unlike this codebase's own convention for similarly consequential actions (`DeleteCustomerDialog`, `markRentalReturned`'s `window.confirm`). The real risk isn't a typo (fails safe into `no_matching_signin`) but a *plausible-but-wrong* email (e.g. a family member's Google account) granting a stranger full customer-role access with one click. **Resolved: added `window.confirm` to both `submitLink` (echoing the exact email back) and `submitUnlink`**, matching the existing pattern exactly. Did not add an identity-preview (matched Google display name) — that needs a new precheck RPC, out of scope for this stopgap; noted as a possible follow-up, not required to clear this finding.

Three Low/informational notes, no action needed: `trim()` is ASCII-space-only (fails closed, not a bypass); a narrow non-exploitable TOCTOU between the ambiguity count and the fetch (Google, not the caller, controls identity creation); and a structural note that the "already-has-a-profile" guard assumes `profiles` rows are never hard-deleted outside the app (true of every current code path) — worth a runbook note, not a code change.

Local gate re-run clean after both fixes: `tsc -b`, `oxlint`, `vitest run` (756/756), `npm run build` — all exit 0.
