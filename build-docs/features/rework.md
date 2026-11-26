# Rework (complaint redone for the same problem)

Status: **BUILT; enums + core LIVE (2026-11-26); salary migration NOT applied; branch pushed, NOT merged.** Worktree `_local_only/worktrees/rework`,
branch `feat/rework`, rebased on origin/main 7c5bc56.

## As built (differences from the plan below, and why)
- **Renumbered again to `20270102…` and regenerated from LIVE bodies (2026-11-26, at "go apply" pre-check):** a parallel
  session applied `20270101100000_no_gst_bill` live (branch feat/no-gst-bill, not yet on main), which also made
  `create_service_invoice` 13-argument (`p_no_gst`). Core now copies the live bodies and refuses to run if their md5 moves.
  **Merge order: feat/no-gst-bill before feat/rework** (core requires exactly the 13-argument function).
- **Migrations renumbered** to `20270102100000_rework_enums` / `…100100_rework_core` / `…100200_rework_penalty_salary`:
  `20261229100000` collided with main's `address_choice_not_set`, and main's newer `20261230100000_gst_everywhere`
  redefines `create_service_invoice` (a lower number would have reverted it).
- **Apply order is forced by Postgres:** a new enum value cannot be used in the transaction that adds it, so
  `rework_enums` must be COMMITTED before `rework_core` can be rehearsed or applied. Then `rework_penalty_salary`.
- **No `set_rework_outcome` RPC / offline op.** `create_service_invoice` derives the outcome from the bill: any charge or
  spare ⇒ `paid`, nothing ⇒ `free`. The app's Free/Paid choice only shows/hides spares and the charge. Removes the
  offline-ordering risk and stops "Paid with ₹0" from dodging the penalty.
- **No `rework_escalations` table.** Escalations reuse `approvals` (new `approval_type 'rework'`, ref_id = rework ticket),
  so the existing master-only Approvals page lists and decides them. Reason stored on `service_tickets.rework_escalation_reason`.
  Photos dropped (reason only). A restrictive policy blocks staff inserting a pre-approved rework approval directly.
- **Pending escalations count** toward the penalty until the master approves (safer default: a technician cannot
  escape a deduction just by escalating).
- **Auto-pickers skip rework** (`_auto_assign_next_ticket_to_technician`, `_next_ticket_available_for_technician`):
  an unassigned rework waits for master/ops instead of going to whoever finishes a job next.
- **Guard triggers:** rework columns / the rework type can change only inside the RPCs (direct API edits by staff refused).
- **"Every deduction can be added or omitted by master"** (owner, 2026-11-26): `monthly_adjustments` gains targets
  `late_deduction` and `rework_deduction`; Exclude = omit, Top up = add; master-only insert + delete (undo) by RLS.
- **Unassigned rework → notification** to operation_admin (not a task). **Rework priority = urgent.**
- **Not built:** "Mark as rework" shortcut on the low-rating task (the New Complaint banner + ticket button cover it).
- Precondition guard: `rework_core` refuses to run unless the 12-argument (gst_everywhere) `create_service_invoice` exists.

## Purpose
A completed complaint where the customer says the same problem came back is redone by the same technician by default,
free when nothing is replaced, and counted against that technician, with a master-set penalty. Today:
- Only a derived "Repeat complaint" chip exists (`customersWithRepeatComplaints`) — no link, no free-visit rule.
- `service_visits.needs_revisit` feeds the first-time-fix % report but **nothing ever sets it**.

## Owner decisions (2026-11-26)
- **Linked rework ticket**, original stays completed (accepted proposal; reopening would rewrite invoice/AMC/warranty/incentive history).
- **Q1** Technician raising an invoice on a rework job → ticket tagged **rework-paid**. No approval, no reason, no review.
- **Q2** Any spare on a rework visit → invoice is raised → rework-paid. Free rework = labour only, no spares.
- **Q3** Rework window = **30 days**, a **master-only Settings** value (master can raise it). Outside the window → normal new complaint.
- **Q4** Rework counts against the original technician even after reassignment. **Penalty: after X reworks, deduct ₹Y** — X and Y set by master.
  If a rework is counted while master has not set X/Y → **flag it to master**.
- **Q5** Review incentive is paid for a rating on a rework visit as normal (existing behaviour, no change).
- **Q6** Technician decides on site: Paid → raises the invoice. Free rework → finishes it as rework, then may **escalate "not my fault"
  to master** with a reason. No request needed for rework-paid jobs. Master decides.
- **P1** Rework-paid jobs do **not** count toward X (owner kept this after the avoid-the-penalty-by-charging warning).
- **P2** Per salary month, the first X reworks are free of penalty; **every rework after the Xth deducts ₹Y** (e.g. X = 10, Y = ₹200, 13 reworks ⇒ ₹600).

## Flow
1. **Raise** (master / operation_admin): completed ticket → "Mark as rework" + reason. Shortcuts: banner on the new-complaint form when the
   same customer + product had a job completed inside the window; "Mark as rework" on the low-rating (<3) ops task.
2. **Assign** to the technician of the original's last completed visit via the existing assign path (leave / overlap / inactive respected).
   Unavailable → unassigned + ops task. Master / operation_admin reassign with existing `assign_ticket_technician`.
   `rework_responsible_technician_id` is fixed at raise and never changes on reassign.
3. **On site:** REWORK badge + original job summary (`getTicketEvidence`). Before Spares the app asks **"Free rework or Paid?"**
   - **Free rework:** spares step hidden, charge locked ₹0, ₹0 invoice. Visit timer = rework time.
   - **Paid:** normal spares + charge + invoice (technician enters the service charge as on any paid job). Tag rework-paid.
   - Adding a spare in Free mode is not possible in the UI; the server converts a ₹0-with-spares submission to rework-paid anyway (Q2).
   - Choice locked once the invoice exists.
4. **"Not my fault" escalation:** after a free rework is completed, the technician sends one request (reason ≥10 chars, optional photos).
   Master approves → not counted for penalty/KPI; rejects → stays counted. Technician notified.
5. **Penalty** (salary month): see below.
6. **Report** per technician: free reworks, rework-paid, rework rate, rework hours, escalations approved/rejected, penalty amount.

## Penalty logic
- Settings (master-only): `rework_window_days` (default 30), `rework_penalty_free_count` (X), `rework_penalty_amount` (Y). X/Y empty = "not set".
- Counted rework = rework ticket, responsible technician = T, completed in the salary month, outcome `free` only (P1), excluding approved escalations.
  Pending escalations are not counted; the HR Compute screen shows "N rework escalations pending — decide first".
- Deduction for the month = `greatest(counted − X, 0) × Y` (P2). Shown as its own `rework_deduction` line on the salary slip; net still floored at 0 (existing rule).
- **Not set flag:** when a rework is completed and X or Y is empty → notification + one open master task "Rework penalty not set"
  (dedup: one open task, count updated), mirroring the arrival-mismatch task pattern.
- Locked (posted) salary months are never changed retroactively; a later decision affects only an unlocked month.

## Architecture
### Migration A (rework core) — complaint/invoice side
- `ticket_type` + `'rework'` (new type ⇒ AMC-visit consumption, warranty recalc, rental and installation-incentive branches in
  `create_service_invoice`, all keyed on `type`, skip automatically).
- `service_tickets` + `rework_of_ticket_id` (FK self), `rework_responsible_technician_id`, `rework_reason`, `rework_raised_by`,
  `rework_raised_at`, `rework_outcome` (`null | 'free' | 'paid'`). Type stays `'rework'` in both outcomes; outcome carries the tag.
- Partial unique index: one open rework per original ticket.
- `rework_escalations`: `ticket_id` unique, `visit_id`, `technician_id`, `reason`, `photo_urls`, `status` (`approval_status`), `decided_by`,
  `decided_at`, `decision_note`. RLS: technician reads own, staff read org; writes only via RPCs.
- `settings` + the three columns above; master-only update via existing settings RLS/RPC (verify role check during build).
- RPCs (SECURITY DEFINER, role + org checks, anon EXECUTE revoked):
  - `mark_ticket_rework(ticket_id, reason)` — master/op admin; completed, inside window, test flag inherited; sets `needs_revisit` on the original visit.
  - `set_rework_outcome(visit_id, 'free'|'paid')` — owning technician; offline-queued before `service_invoice.create`.
  - `create_service_invoice` — added rule: on `type='rework'`, outcome `free` ⇒ force ₹0 and reject/convert spares to `paid` (Q2);
    outcome `paid` ⇒ chargeable normally. Never trusts the client's `p_is_chargeable` for rework. md5-pin the live body first.
  - `request_rework_escalation(ticket_id, reason, photos)` — owning technician, free outcome, completed.
  - `decide_rework_escalation(id, decision, note)` — **master only**.
  - Trigger on rework completion → "penalty not set" flag when X/Y empty.
### Migration B (penalty) — salary side, separate
- `compute_salary` + `v_rework_deduction`; `salaries` + `rework_deduction` column. This is the payroll money path ⇒ follows the
  incentive-stream pipeline: rehearsal, md5 pins, rollback exercised, typed **APPROVED**, never Compute the real month.
### UI
- Admin: mark-rework dialog, new-complaint banner, badges (Rework / Rework-paid / "Rework raised → #456"), filter chip, master escalation queue,
  Settings fields (master-only), salary slip line.
- Technician: badge + original summary, Free/Paid step, escalation button on completed free rework. en + ta strings.

## Impact map
| Touches | Risk |
|---|---|
| `ticket_type` enum | Every label/filter/report on type, `_detect_ticket_type`, WhatsApp text. Missing case → blank label. |
| `create_service_invoice` | All service invoices. Rule added only for `type='rework'`; existing invoice tests re-run. |
| `compute_salary`, `salaries` | Every technician's net pay. Separate migration + APPROVED gate. |
| Settings page | New master-only fields; op admin must not edit them. |
| Assign path | Reused unchanged. |
| `needs_revisit` | First-time-fix % drops for affected technicians (intended). |
| Incentives | `service_income` follows invoice revenue (₹0 free rework ⇒ 0). Review incentive unchanged (Q5). Pending installation credit on the original not clawed back (flagged to master). |
| Tier promotion | Verify whether job counts include rework; decide during R1. |
| Offline queue | New op ordered before invoice creation. |

## Edge cases
- Original not completed / cancelled / outside window → reject. Open rework exists → reject (unique index covers double-click).
- Several visits on original → last completed visit's technician. That technician inactive / on leave / busy → unassigned + ops task.
- Rework of a rework → allowed; responsible = whoever completed the previous one.
- Modified client sends a charge or spares on a free rework → server converts to rework-paid or charges ₹0, never silently free-with-parts.
- Offline: outcome op fails ⇒ invoice op fails (no ordering gap).
- Escalation twice / after decision / on rework-paid → rejected.
- Escalation decided after the month is locked → no retro change.
- Mark by mistake → cancel the rework ticket (existing cancel) → `needs_revisit` reverted, not counted.
- Original AMC / warranty / installation → no AMC visit consumed, no warranty date moved.
- Master sets X/Y mid-month → penalty applies at next Compute for all counted reworks of that month.

## Acceptance criteria
1. Only master / op admin can mark rework; inside the master-set window only.
2. Linked ticket auto-assigned to the last completed visit's technician or unassigned + ops task; reassign keeps the responsible technician.
3. Free rework: ₹0 invoice, no spares, even with a tampered client. Paid: normal invoice, tagged rework-paid, no approval.
4. One escalation per free rework; master-only decision; approved ones excluded from counts.
5. Penalty = `max(counted − X, 0) × Y` in SQL tests (0, X, X+1, X+3 reworks; rework-paid and approved escalations excluded); net never below 0; locked months untouched.
6. Completed rework with X/Y unset ⇒ one open master task + notification.
7. No AMC visit consumed / warranty date moved by a rework (SQL test).
8. `needs_revisit` set on raise, cleared on cancel.
9. Report shows the per-technician rework numbers for a date range.
10. en + ta strings; tsc -b, vite build, vitest, SQL tests green.

## Build order (each phase: build → test → stop for review; DB writes only on "go apply" / APPROVED by name)
- **R1** Migration A + rollback + rehearsal test.
- **R2** Admin: mark-rework, banner, badges/filter, Settings fields.
- **R3** Technician: badge, Free/Paid step, escalation.
- **R4** Master escalation queue + notifications + "penalty not set" task.
- **R5** Migration B (penalty in salary) + salary slip line.
- **R6** Reports.

## Assumption to confirm
- X counts per salary month (resets each month), matching monthly payroll.
