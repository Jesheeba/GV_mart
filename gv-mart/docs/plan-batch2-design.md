# Batch 2 — design (read-only investigation, 2026-10-12)

Status: **DESIGN ONLY.** No code, no live DB write was made. Waiting for approval. Referral transparency is in
`docs/plan-referral.md`.

Scope: (1) item 16 installation charge, (2) item 11 time slots, (3) item 1 the AMC contract, (4) item 15 technician
section + reviews, (5) the test-customer flag. Every figure below was read from the live database or the code on
`origin/main` (663e820) today; customer names and full phone numbers are deliberately not printed.

## 0. Read first: what I found that changes priorities

1. **The two real technicians are blocked from every other job until 2027.** The only AMC contract's generator assigned its
   first two visits (April and October 2027) to the two technicians at purchase time, and the assignment engine treats "has
   any open appointment, of any date" as busy (a unique index enforces the same thing). So neither technician can be
   auto-assigned a new job today. This is a live operational problem, not just a data oddity (section 3). I recommend
   repairing it first once you approve.
2. **The customer app does NOT use the master slot list.** The customer "Book Service" flow uses work hours minus the
   windows the customer taps as unavailable. Only the admin New Complaint form and the customer "Request callback" flow use
   the three Masters slots. So "copy the customer slots into the master form" has no single thing to copy today (section 2).
3. **The Masters slots are still the unedited seed** (08:00–12:00, 12:00–16:00, 16:00–20:00, created 31 Jul) and sit
   partly outside the working hours you did enter (09:15–17:30). `max_bookings_per_slot` is NULL and no function reads it.
4. **The test customer "jeshee test trigger" does not exist yet** in the real organisation (searched by name and by mobile).
   The flag can be built first; the customer has to be created (by you) or you tell me which row to flag.
5. **No installation incentive has ever been paid**: `incentives_earned` has 0 rows, `installations_logged` 0,
   `installation_incentive_rates` 0, and incentives only compute when the master presses Compute in HR. The flat ₹250
   "installation" rule is the only active rule.
6. **Other sessions' throwaway `__TEST_` organisations are live right now** (a reports test with ~1,100 customers and
   ~1,100 invoices, and another). They are separate organisations, so they do not leak into the real one, but they are why
   whole-database counts look much bigger than the real organisation (4 customers, 1 invoice, 68 leads, 7 tickets, 2
   technicians, 1 AMC contract).

---

## 1. Item 16 — Installation charge as the technician's incentive

### 1.1 Decision recorded
One master-editable amount per product (`products.installation_charge`). It pre-fills the installation ticket; when the
technician completes the installation, that amount is credited as **their incentive**. Technician's incentive only; no
invoice, GST or revenue change.

### 1.2 How installation incentives work today (live)
| Piece | State |
|---|---|
| `installation_incentive_rates` (by product / category / capacity / configuration, `flat_amount`) | 0 rows. Most-specific match wins (`installation_rate_for`: product×8 + capacity×2 + configuration×2 + category×1) |
| `incentive_rules` type `installation` | 1 active rule: threshold 1, amount ₹250 — a flat **monthly** bonus per technician once ≥1 unit is installed (not per unit) |
| `installations_logged` | 0 rows. Written only by the technician's `create_service_invoice(..., p_installations)`; the product is picked by the technician, **not** linked to the ticket's product; no unique key |
| `incentives_earned` | 0 rows. Monthly, aggregated; no ticket reference, no status/approval/paid columns; rule rows are never refreshed once inserted |
| `compute_incentives(org, period)` | master-only, **manual** (HR → Incentives → Compute). Per-unit rate rows are recomputed on each run; the flat rule row is inserted once |
| payout | `compute_salary` sums `incentives_earned` into `salaries.incentives`. No paid flag, no incentive approval type |
| ticket creation | `create_sale` creates **one** installation ticket per cart line (regardless of qty); `create_rental` also creates one. No manual "create installation ticket" path found |
| completion | `create_service_invoice` has **no status guard** — calling it twice would create a second invoice and a second set of install rows |

### 1.3 Proposal
**Data**
* `products.installation_charge numeric(12,2) null check (>= 0)`; NULL/0 = no incentive.
* `service_tickets.installation_charge_snapshot numeric(12,2) null`, filled by a **BEFORE INSERT trigger** for
  `type='installation'` from the ticket's product (one place, instead of re-patching the sale functions). Master may edit it
  on the ticket until completion; every edit is audited (the `audit_service_tickets` trigger already exists).
* New ledger `installation_incentive_credits (ticket_id, visit_id, technician_id, product_id, qty, amount, status, approved_by,
  approved_at, created_at)` with **UNIQUE (ticket_id, technician_id)**. A credit is the single source of truth per ticket,
  so it cannot double count.
* `compute_incentives` adds one source: the sum of this month's non-void credits, written as an `incentives_earned` row
  (new nullable `credit_period` source / extra source column; the existing "exactly one source" check is extended).

**Credit rule**
* Created inside `create_service_invoice` when the ticket is `installation` and not already completed:
  `amount = snapshot × qty`, `qty` = units the technician logged for the ticket's product, minimum 1.
  `ON CONFLICT (ticket_id, technician_id) DO NOTHING` protects against a double call.
* **Add the missing guard** `if ticket.status = 'completed' then raise` and drop the legacy 10-argument overload (two
  overloads of `create_service_invoice` are live).
* Reassignment: the credit goes to the technician who **completed** the visit (`service_visits.technician_id`).
* Cancelled: nothing is credited (no completion). Completed-then-voided (no such function exists today): credit → `void`.
* Reopened: there is no reopen RPC. If one is added later it voids and re-credits through the same unique key.

**Precedence — no double counting**
1. A product with `installation_charge > 0`: the unit is paid by the charge **only**; `installation_incentive_rates` is
   skipped for that product's units (rates remain the fallback for products with no charge).
2. The flat monthly ₹250 rule is separate and threshold-based. It would still stack on top. **Owner decision** (see 1.5):
   disable it, or keep it as a stated monthly bonus.
3. Free-picked `installations_logged` rows on non-installation tickets (the picker shows on every visit) are not paid by
   the charge, only by rates/flat rule as today.

**UI**: Masters product form (new "Installation charge — technician incentive, not billed" field); ticket page shows the
snapshot on installation tickets (master-editable until completion, labelled internal); technician completion screen
pre-fills the ticket's product and shows "Installation incentive ₹X" (display only); HR Incentives gains an
"Installation (ticket)" row type with a link to the ticket and approve/void.

### 1.4 Where master approval is needed (pay-related)
1. Setting or changing `products.installation_charge`. 2. Editing a ticket's snapshot. 3. Voiding/approving a credit.
4. Pressing Compute and compute-salary (already master-only). 5. The flat rule and the per-unit rates (keep/disable).
There is currently **no** incentive approval type in `approvals`; the proposal uses the credit `status` instead.

### 1.5 Open questions
* Keep the flat ₹250 monthly bonus, replace it, or disable it? (recommend: disable — it would double-pay on top of the
  new per-product amount)
* Quantity: the sale makes one ticket per cart line. Pay `snapshot × units logged`, or `snapshot × cart qty`, or one per
  ticket? (recommend: units logged, minimum 1)
* Should a credit need master approval **per ticket**, or is the monthly Compute click the only gate? (recommend: credits
  are created `pending` and counted by Compute only after approval; or auto-approved with void available)
* What happens to `installation_incentive_rates` once charges exist — hide the tab or keep as fallback?

### 1.6 Migration, risk, effort
Migration: column + snapshot column + trigger + credits table (RLS: master all, technician own select) + replace
`create_service_invoice` + replace `compute_incentives`. Risks: both functions are money-adjacent and have several older
bodies (use the live body, not a migration file). Effort **3–4 days** with tests. Existing numbers: none change until a
charge is set (0 incentive rows today).

---

## 2. Item 11 — Time slots: one source of truth

### 2.1 What exists (live + code)
| Surface | Timing model today |
|---|---|
| Customer app "Book Service" (`BookServicePage.tsx`, RPC `book_service_ticket`) | **No slots.** Work hours (`settings.work_start/work_end` = 09:15/17:30) minus customer-tapped unavailable windows; "narrow" if ≤ 90 min (`narrow_window_threshold_minutes`) |
| Customer "Request callback" (`request_callback`) | Master slots (`appointment_slots`) |
| Admin New Complaint (`NewComplaintPage`, `_create_complaint_ticket_internal`) | Date + master slot chips; slot required; past slots filtered for today |
| Appointments page / ticket detail / ticket list | Show only a clock time (`scheduled_at`) or "always"; **no slot name or window** (an RPC `ticket_list_slot_info` exists, unused) |
| Technician home / job detail | `formatTime(scheduled_at)` → a slot booking shows as "08:00" with no window |
| Assignment engine (`_auto_assign_ticket_internal`, `assign_ticket_technician`) | Uses only the **date**; ignores slot and window |

Live slot data: `appointment_slots` has exactly the three seed rows (Morning 08–12, Afternoon 12–16, Evening 16–20), all
created 31 Jul and never edited; `max_bookings_per_slot` is NULL on all and **no function reads it**.
What you *have* entered: work hours 09:15–17:30, narrow threshold 90, default durations paid/warranty/amc/installation
= 45/45/30/50, `amc_book_window_days` 7, technician `daily_capacity_minutes` 480. Not read by any code path:
`max_bookings_per_slot`; `appointment_unavailable_windows` (0 rows). `estimated_duration_minutes` is NULL on all live
tickets, so the per-day capacity sum is effectively 0.

Double booking: the only guard is a **unique index** `appointments_one_open_per_technician_idx (technician_id) WHERE status
in ('scheduled','in_progress')` — one open job per technician **regardless of date or slot**. It prevents same-slot
double booking but also stops a technician holding two jobs on different days (the root of the AMC problem, §3). There is
no time-range check anywhere.

### 2.2 Decision needed before building (it reverses an earlier decision)
On 2026-08-04 the owner explicitly **restored** the customer's "tap unavailable windows" booking
(`20260804200000_restore_customer_unavailability_booking.sql`). Replacing it with slots reverses that. Options:
* **A (recommended):** customers choose a date and a **master slot**; the unavailable-windows step is removed.
* **B:** customers keep tapping unavailable windows, but the resulting window must fit inside a master slot.
* **C:** slots become the only thing admins see; customers keep geometry (today's behaviour, just made consistent in display).

### 2.3 Design (Option A)
* **Source of truth:** `appointment_slots` (already master-editable, readable by customers). `work_start/work_end` remain
  attendance hours only. Add a validation in the Masters card: no overlaps, warn when a slot is outside working hours,
  warn/guard when editing a slot with open bookings.
* **One read RPC** `get_booking_slots(p_org_id, p_date, p_include_inactive default false)` → slot id, name, start, end,
  sort order, `is_past` (IST), booked count, capacity, free technicians. Every screen (customer app, New Complaint,
  appointments, ticket detail reschedule, technician app) calls it through one hook and one display helper
  (`formatSlot(appt)` → "Morning (08:00–12:00)").
* **Snapshot** `appointments.slot_start/slot_end` (timestamptz) so retiming a slot never silently corrupts open bookings;
  `slot_id` keeps the live name.
* **Double-booking prevention:** `btree_gist` + `EXCLUDE USING gist (technician_id WITH =, tstzrange(slot_start, slot_end)
  WITH &&) WHERE status in ('scheduled','in_progress') AND technician_id IS NOT NULL`, **replacing** the blunt unique index
  (dropped only after the exclusion constraint is live). Assignment functions switch to a range-overlap test; a race maps
  to "technician busy", not a raw error. Enforce `max_bookings_per_slot` (or free-technician count) in
  `book_service_ticket` and `_create_complaint_ticket_internal`.
* **Capacity model:** default `estimated_duration_minutes` from the master durations so the per-day capacity sum is real.

### 2.4 Phases
A: add columns, `get_booking_slots`, `reschedule_appointment`, shared display helper (works for both slot and geometry
rows). B: switch customer app + admin to the slot RPC (old `book_service_ticket` overload kept for old app versions).
C: overlap logic + exclusion constraint (backfill the 7 live appointments first). D: remove geometry
(`appointment_unavailable_windows`, `_largest_free_window`, narrow threshold).

### 2.5 UI files
Customer: `BookServicePage.tsx` (slot chooser), `services/customerApp.ts`, `hooks/useCustomerApp.ts`, validation.
Admin: `NewComplaintPage.tsx` (shared hook), `AppointmentsPage.tsx`, `TicketDetailPage.tsx` (+ reschedule action),
`TicketsListPage.tsx`, `AppointmentSlotsCard.tsx` (validation). Technician: `TechnicianHomePage.tsx`, `JobDetailPage.tsx`,
map/job cards.

### 2.6 Risks / effort
Reverses the 2026-08-04 decision; slot hours vs work hours must be reconciled (which is authoritative for attendance?);
geometry-booked future appointments have no slot and must be backfilled before the constraint; switching from "one job at
a time" to per-slot overlap increases same-day load (the capacity model must be real). Effort **6–9 days**.

### 2.7 Open questions
Option A, B or C? Are slots 08–20 right, or should they sit inside 09:15–17:30? Should retiming a slot move open
bookings? Should technicians be allowed more than one job per slot (capacity) or strictly one?

---

## 3. Item 1 — The AMC contract (read-only trace)

### 3.1 The contract (real organisation; exactly one — the other two AMC rows belong to other sessions' `__TEST_` orgs)
| | |
|---|---|
| contract / customer | `711677e3…` / `0c402f1f…` (customer ends …97, created 8 Oct 12:59 IST, flagged `needs_setup`) |
| plan | "Silver": 3 years, 2 visits/year, ₹12,000 (₹4,000/yr), plan updated 20 Jul |
| dates | start **2026-10-08**, expiry **2029-10-08**, status active, `next_service_date` 2027-04-08 |
| created | 2026-10-08 15:01 IST, **staff-sold via `sell_amc_plan`** (no invoice; this is the 8 Oct referral-capture test sale — the AMC lead says "AMC sale, referred by technician") |
| visits | 6 service tickets + 6 appointments, all created in the same transaction |

| # | scheduled (IST) | weekday | technician | ticket status |
|---|---|---|---|---|
| 1 | 2027-04-08 09:00 | Thu | T1 | assigned |
| 2 | 2027-10-08 09:00 | Fri | T2 | assigned |
| 3 | 2028-04-08 09:00 | Sat | — | open |
| 4 | 2028-10-08 09:00 | **Sun** | — | open |
| 5 | 2029-04-08 09:00 | **Sun** | — | open |
| 6 | 2029-10-08 09:00 | Mon (= expiry day) | — | open |

No visit completed, no invoice linked to a visit ticket, so no financial exposure.

### 3.2 Why the times are wrong (generator `sell_amc_plan`, live body)
```
v_visit_date := p_start_date + make_interval(months => v_interval_months * i);
... scheduled_at = (v_visit_date + time '09:00') at time zone 'Asia/Kolkata'
perform _auto_assign_ticket_internal(v_ticket_id, ...)   -- inside the loop, at purchase time
```
* **09:00 is a hard-coded constant** — not from the slot list (08/12/16) and not from `work_start` 09:15; `available_from`,
  `available_to`, `slot_id` are all NULL. (The stored instant is a correct IST 09:00; I found **no** 5.5-hour UTC/IST
  confusion in the stored rows. If a screen shows another time that is a display issue I did not inspect.)
* **No working-day roll**: visits 4 and 5 fall on Sundays (`lead_work_days` = Mon–Sat), visit 3 on Saturday.
* `12 / visits_per_year` is **integer division** (5 visits/year → 2 months, 7+ → 1).
* The first visit is 6 months after purchase and the last lands on the expiry day.
* **SLA is computed from assignment time, not the visit date**: tickets 1–2 got `sla_due_at = now()+24h` and are already
  breached months before the visit.
* Same hard-coded pattern in `sell_amc_plan_onsite`, `renew_amc_plan`, `create_sale` (AMC add-on and warranty visits).

### 3.3 Why different technicians were assigned "to the same time"
They were not at the same instant — all six visits share the same time of day (09:00) because it is a constant, and the two
technicians got visits 1 and 2 on **different dates**. The assignment predicate (`_auto_assign_ticket_internal`):
```
and not exists (select 1 from appointments a
                where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
```
has **no date or time condition**. The moment visit 1 (April 2027) is assigned to T1, T1 counts as "busy" for visit 2, so
visit 2 goes to T2, and visits 3–6 find nobody free (two technicians) and raise 4 `ticket_unassigned` notifications. For a
future date the attendance check is bypassed, which is why two technicians were assignable for 2027. The same rule in
`_auto_assign_next_ticket_to_technician` returns "already busy", so **T1 and T2 cannot receive any other job**. There is no
AMC cron, so nothing re-assigns visits 3–6 near their date.

### 3.4 Logic fix
One shared `_schedule_amc_visits(contract, plan, start, years, address)` used by all four callers:
1. Create visit tickets **unassigned**, status open, `sla_due_at` NULL, with a window; assign when the date nears
   (`amc_book_window_days`, a daily job, or on a technician's completion that day).
2. Dates: `round(12.0 / visits_per_year * i)` months using numeric; cap at expiry; decide whether visit 1 is at +interval
   (today) or at purchase.
3. Roll to a working day from `lead_work_days` (+ a holiday list if you want one — none exists).
4. Time from the master slot list (§2), never before `work_start`; set `slot_id`, `available_from/to`, `slot_start/end`.
5. Assignment: date-aware overlap test (§2.3); SLA relative to the visit date.
6. Idempotence: unique (contract_id, visit_no).

### 3.5 Repair plan for the one contract (nothing run)
1. **Backup** (snapshot tables): `_bak_amc_20261012_{contract,tickets,appts,notifs}` via `CREATE TABLE AS` for the contract
   id, its tickets, their appointments and their notifications.
2. **Dry-run diff** (SELECT only): per visit, current vs proposed `scheduled_at` (Sunday → Monday; time from the chosen
   slot or 09:30), and the technician that would be released. Review before any write.
3. **Update rule**: appointments `scheduled_at/available_from/available_to/slot_id` only where `status='scheduled'`; for
   tickets 1–2 `technician_id = NULL`, `status='open'`, `assigned_at = NULL`, `sla_due_at = NULL` (frees T1/T2 at once); leave
   the contract row and `next_service_date` alone; mark the 4 stale `ticket_unassigned` notifications read.
4. **Rollback**: restore from the `_bak` tables by id; drop them after sign-off.
5. **Decision for you:** this contract is the 8 Oct referral **test** sale. Options: repair as above, or cancel/delete the
   test contract and its 6 tickets (you said do not touch the 8 Oct rows until the cleanup audit). Either way the
   technicians must be released.
Risks: the same generator is live, so any AMC sold before the fix reproduces the problem — pause AMC sales or ship the fix
first; re-check warranty visits created by `create_sale` / `register_product_via_qr` (same pattern).
Effort: generator fix + shared helper **2–3 days**; repair **0.5 day** after approval.

---

## 4. Item 15 — Technician section and reviews

### 4.1 Metrics: what exists vs what is new
| Metric | Status | Source / gap |
|---|---|---|
| Name | exists | `profiles.full_name` |
| Days present | partial | `attendance` rows with check-in; no summary function |
| Days absent | **new** | no absent rows, no weekly-off/holiday calendar. Needs a master "working days" definition minus leave |
| Total calls | exists | visits (`jobs_done`, `completed_visit_count`) |
| Revenue | exists | Σ `service_visits.service_charge` (service only; ≠ invoice total) |
| Average call value | exists | `technician_kpi_summary` — **paid invoices only**; state the basis on screen |
| Customer app rating | exists | `ratings.stars` (live: 0 rows); average per technician in `report_performance` |
| Google reviews with stars | partial | `customer_members.google_review_*` (one per member, last write wins, **unverified**, 0 live) |
| Referral revenue (service/sales/AMC) | **new** | only counts exist; no referrer on invoices/contracts (see referral plan) |
Overlap: `report_performance` (reports branch, live in DB, not on main) already returns jobs, revenue, avg rating, review
count, installs per technician — reuse it; build only absent days, verified reviews and referral revenue.

### 4.2 Existing review mechanisms
* `ratings.google_review_clicked` is set by `mark_google_review_clicked` — a **tap** on the link, no proof. The only
  incentive rule type `review` pays a flat amount per month when click count ≥ threshold (no such rule live).
* `log_technician_google_review` writes member columns with a technician-supplied photo value; **nobody verifies it**. I
  could not confirm whether the photo is uploaded to storage or stored as a data URL (needs a look at `PhotoCapture`).
* Policy `ratings_write_own_technician` is ALL — a technician can set `google_review_clicked` or insert a rating directly
  through the API. Should be tightened.
* `settings.google_review_url` **already exists** and is editable in Masters → Settings; `review_link_min_stars` (live
  3.5) decides when the link is shown.

### 4.3 Proposed review flow
* **At completion** the technician is asked "Customer review taken?" → yes/no, stars, optional proof photo (uploaded to the
  `ticket-photos` bucket, storing the **path**), saved per ticket + technician.
* **Table** `ticket_reviews (ticket_id, visit_id, technician_id, review_taken, stars 1–5 null, photo_path null, status
  pending|verified|rejected, verified_by, verified_at, reject_reason)`, UNIQUE (ticket_id, technician_id). RLS: technician
  inserts/selects own; ops/master select and update status.
* **RPCs**: `submit_ticket_review` (technician), `verify_ticket_review(review_id, approve, reason)` (ops/master).
  Existing `log_technician_google_review` and the member columns are folded in so there is one source for
  `total_reviews`.
* **Verification queue** for operations (pending reviews with photo, approve/reject).
* **Incentive**: master-editable amount **per verified review, regardless of stars** — a new rule type `review_verified`
  (or `incentive_rules.amount` on it), credited per verified review through the same credit-ledger approach as §1 (unique
  per review) and summed by Compute. No reward to customers.
* **Customer asks, both ways:** (a) WhatsApp message with the link after service — new template `review_request`
  (`{{1}}` customer name, `{{2}}` complaint, `{{3}}` review link; variable map as the existing templates), added to the
  Automation → Templates list with `approval_status = pending`; sent from the completion path through `sendMessage` (the
  render function only substitutes passed variables, so `review_link` from `settings.google_review_url` is added);
  (b) a **QR code** of the same link on the technician's phone (a QR component; I did not confirm a QR library is already
  in `package.json`).
* Technician section gains: days present/absent, verified reviews + average stars, review claim rate (existing flag
  logic), referral revenue.

### 4.4 Master-approval points (pay-related)
Review incentive amount; each verification (determines pay — consider master-only or two-step); Compute/compute-salary;
changing the review link (changes the QR and every WhatsApp message).

### 4.5 Risks and questions
* Proof photos are easy to fake; manual verification plus the existing claim-rate flag are soft controls only.
* **Review gating**: today the link is shown only when stars ≥ `review_link_min_stars`. Asking only satisfied customers is
  something review platforms commonly discourage — confirm the intended policy before building the new "ask everyone"
  flow (I am not giving a legal opinion).
* Meta template category: a review request may be classed as *marketing*, not *utility*; approval time and cost.
* Incentives are paid to technicians, not customers (as you specified); confirm this is acceptable under the platform's
  rules.
* "Days absent" needs your working-days definition (weekly off, holidays).
Effort **5–7 days** (reviews + verification + template/QR) plus **2–3 days** for absent-days and referral revenue
(after the reports branch merges).

---

## 5. Test customer flag

### 5.1 Design
* `customers.is_test boolean not null default false` + partial index; helper `is_test_customer(uuid)`
  (STABLE SQL) for single lookups; set-based reads use an anti-join, not the function per row.
* Only the master can set/clear it (guard trigger); not exposed in the customer app; it does **not** stop normal use —
  sales, tickets, AMC, WhatsApp and crons keep working so end-to-end tests are real.
* Per your rule: until the flag exists, no invoices, tickets or AMC are created for it. **The customer does not exist yet** —
  create it (or tell me the row) and flag it in the same step.

### 5.2 Everything that must exclude it
Live functions are already in the database; `report_*` lives on branch `fix/reports-sql-aggregation` (live in DB, not on
main), and main still aggregates reports client-side — so the flag needs **both** the SQL and the client code (or the
reports branch merged first).

| Group | Functions / code | Why | Change |
|---|---|---|---|
| Money (do first) | `technician_attributed_revenue`, `technician_attributed_sales`, `technician_finder_conversions`, `technician_installation_count`, `_technician_paid_earning`, `technician_kpi_summary`, `reward_candidates` (and via them `compute_incentives`, `compute_salary`) | a test visit/invoice would inflate **pay** | join ticket/invoice → customer, `not is_test` |
| Reports (SQL) | `_report_invoice_base` (one change covers `report_sales_service`, `report_pnl`, `report_top_customers`, `report_customer_totals`), `report_customer_totals` (raw counts + repeat), `report_product_sales`, `report_coverage`, `report_performance`, `report_feedback`, `report_ops_resolution` | revenue, customers, coverage, ratings | exclude test customer's invoices/tickets/visits |
| Dashboards / client | `services/reports.ts` (`getSalesServiceReport`, `getPnlReport`, `getPerformanceReport`, `getTopCustomersBySales`), `reportsInsights.ts` (`getCustomerTotals`), `OwnerDashboard`, `SalesDashboard`, `huddle.ts`, `SalesListPage` stats, `CustomersListPage` counts (`getCustomerFilterCounts`), `TechniciansListPage` | read raw rows | filter in the query |
| Leads | `get_lead_funnel`, `followup_counts`, `list_followups`, `list_leads_without_followup`, `list_post_service_followups`, `run_lead_followup_notifications` | counts/queues/digest | exclude by lead/ticket customer (leads with no customer row need a mobile match) |
| Round robin | `_trg_lead_auto_assign` (BEFORE INSERT on `leads`) → `_lead_rr_pick` | a test lead advances `lead_rotation` | skip the rotation advance when the lead's customer is test; `_lead_rr_pick` unchanged |
| **Keep working (do NOT exclude)** | `wa-scheduled-tasks` (AMC reminders, feedback), `wa-milestone-dispatch`, milestone/notify triggers, `wa_*` RPCs, search, create_sale/sell_amc/`book_service_ticket`/`create_service_invoice`, `refresh_*`, `run_rental_billing`, delete/impact functions | the test customer must receive real flows; WhatsApp goes only to the one test number | none |
| Not needed | `report_expenses_*`, `compute_salary` itself, `dashboardMath.ts`, `_lead_rr_pick` | no customer link / pure math | none |

### 5.3 Phases
0 column + helper + flag the one row (changes nothing). 1 pay functions. 2 SQL reports (`_report_invoice_base` first).
3 leads/round robin. 4 client queries (or merge the reports branch). Tests per phase: one test customer with an invoice,
ticket, visit and rating must not change any total. Effort **3–4 days**. Existing numbers: none change until the flag is
set on a row that has activity (today there is none).

---

## 6. Recommended order
1. **Repair the AMC technician block** (after you approve §3.5) — it is hurting operations today.
2. Test-customer flag phases 0–1 (cheap, protects pay).
3. AMC generator fix + slot source of truth (they share the slot list) — §3.4 + §2.
4. Item 16 installation charge.
5. Technician reviews + section (item 15), after the reports branch merges.
6. Referral transparency (`plan-referral.md`) in parallel with 4–5.

## 7. Effort summary
| Package | Days |
|---|---|
| Test-customer flag (all phases) | 3–4 |
| AMC generator fix + repair | 2.5–3.5 |
| Slots source of truth + double-booking constraint | 6–9 |
| Installation charge incentive | 3–4 |
| Reviews + verification + template/QR | 5–7 |
| Technician metrics (absent days, referral revenue) | 2–3 |
| Referral transparency (see referral plan) | 4–6 |

## 8. What would change in existing numbers
* Flag: nothing today. * Installation charge: nothing until a charge is set. * Slots: appointment display changes;
the "one open job per technician" rule disappears, so **same-day load per technician can increase**. * AMC repair: the
contract's six appointment times/technicians and two ticket SLAs. * Reviews: `total_reviews` changes meaning (verified
only). * Technician section: new columns; "average call value" basis stated.
