# PHASE 2 PROPOSALS — not built, for owner review only

Nothing in this file has been implemented. These are ideas surfaced while
investigating the 2026-10-28 nav/feature audit that are out of scope for
"no other changes" but worth a deliberate yes/no later.

## 1. Retire the standalone Complaints tab

**Current state:** untouched, exactly as on `origin/main`.

**Finding (code-verified, not assumed):** `ComplaintsPage.tsx` is a
read-only, two-tab view ("Overdue SLA", "Repeat Complaint") over the same
`service_tickets` table Service's own ticket list uses:

- Its "Overdue SLA" tab uses `listOverdueSlaTickets`, whose predicate
  (`sla_due_at < now AND status NOT IN (completed, cancelled)`) is exactly
  Service's existing `isTicketOverdue` — same logic, different screen.
- Its "Repeat Complaint" tab (`listRepeatComplaintTickets`, 90-day
  customer+product repeat count) has a close cousin already live on Service:
  `useRepeatComplaintCustomers` (90-day customer-level repeat), which Service
  already uses to badge rows in both table and kanban views.
- Every row click (`goToTicket`) just navigates to
  `/admin/service/:id` — Complaints has no actions of its own (no create,
  assign, resolve, escalate). It's a lens onto Service's data, not a
  separate workflow.

**Proposal:** once the owner confirms, retire the Complaints tab/route and
rely on Service's own quick-filter chips (its existing "Overdue" chip
already covers the SLA case; this change's new "Repeat complaint" chip —
commit `e8d3b67` — now covers the other). Redirect `/admin/complaints` to
`/admin/service` for any bookmarked links instead of a 404.

**Why not done now:** instruction (2) was explicit that removing a feature
is outside the client's current scope ("no other changes"). This proposal
is the same idea, deferred to an explicit go-ahead.

## 2. Fuel & Bike Allowances rename

**Current state:** not applicable yet — `origin/main` has no Expenses
feature at all (see `DECISIONS.md` §1). The Monthly Expenses work
(bike/fuel allowance tracking, technician KM log) exists only on
`ui-ux-improvements` via `feat/monthly-expenses`, not yet on `main`.

**Proposal, ready to apply the moment that feature merges to `main`:**
rename the sidebar label for that feature from "Expenses" to "Fuel & Bike
Allowances" (translation-only change, `nav.expenses` in both `en.json` and
`ta.json`), since it reads as a second Accounts/money-out ledger under its
current name when it's actually a bike/fuel allowance workflow. No code
logic change — just the label and, optionally, nesting it under the "Money"
sidebar group alongside Accounts and HR.

## 3. Campaigns → Automation send path

**Current state:** notice made visible (commit `a1c5496`); no send path
added.

**Proposal:** wire Campaigns' "activate" action to Automation's existing
WhatsApp send machinery (Templates/Phrase Manager/Conversations) so an
activated campaign can actually dispatch, instead of only logging intent.
This is real backend work (approval flow, rate limits, opt-out handling)
and deliberately out of scope for a nav/IA change — flagging it here so it
doesn't get lost, not attempting it blind.
