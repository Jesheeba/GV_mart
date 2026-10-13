# Referral transparency — current state and design (read-only investigation, 2026-10-12)

Status: **DESIGN ONLY**, nothing built or written. Companion to `docs/plan-batch2-design.md`.

Complaint: the referral feature does not show exactly **who** referred **whom**, nor whether the referral bonus is
**credited** to the technician.

## 1. Short answer: why it looks that way
1. A referral is **not a record**. It is a side effect: a `leads` row with `source='referral'`, `status='won'`,
   `owner_id = <referring technician>`, `customer_id = <buyer>` plus a "converted" note. Invoices, AMC contracts and
   warranties carry **no** referrer or lead column; only `service_tickets.lead_id` links back.
2. The "bonus" is not tied to a referral. It is a **flat monthly amount** per technician, paid when the number of *completed
   referred tickets* in the month reaches a threshold. The ledger (`incentives_earned`) has no lead/ticket reference and no
   status.
3. **Live today there is no referral bonus at all:** no `finder_credit` rule exists (the only incentive rule is the
   installation one), `incentives_earned` has 0 rows, and none of the 7 referred tickets is completed (finder conversions
   = 0 for everyone). The 3 referral leads in the real organisation are the 8 Oct test rows (sale, service, AMC).
   "Credited" therefore cannot show anything yet.

## 2. Where a referral is stored today
| Entry point | Function | Referrer (who) | Referred (whom) | Rows written |
|---|---|---|---|---|
| Walk-in sale | `create_sale(…, p_referred_by_technician_id)` | `leads.owner_id` = technician | `leads.customer_id` = buyer | lead `source='referral'`, `won`, activity "Walk-in sale, referred by technician"; lead id stamped on the generated warranty/installation/AMC tickets |
| Service complaint (admin) | `_create_complaint_ticket_internal(p_referred_by_technician_id)` | technician | customer | lead `referral`/`won`, "Service ticket, referred by technician"; `service_tickets.lead_id` |
| AMC (admin) | `sell_amc_plan(…, p_referred_by_technician_id)` | technician | customer | lead `referral`/`won`, "AMC sale, referred by technician"; all visit tickets get `lead_id`. **No invoice** is produced |
| AMC self-service (customer app) | `renew_amc_plan(…, p_referred_by_technician_name text)` | technician looked up by **free-text name** (case-insensitive); a non-match is a silent no-op | the logged-in customer | lead `referral`/`won`, "AMC self-service purchase, referred by <name>" |
| AMC on-site (technician sells) | `sell_amc_plan_onsite` | **not a referral**: `owner_id` = the *selling* technician | customer | lead `source='field'`, `won`; invoice `type='amc'`, `sold_by`, `amc_contracts.invoice_id` |
| Technician enquiry | `generate_enquiry_lead` | `owner_id` = technician | `customer_id` (may be NULL: name + mobile only) | lead `source='field'`, `new`; only becomes bonus-eligible if later quoted/sold |
| Customer app / WhatsApp | `request_callback`, `_whatsapp_lead_upsert` | none | customer | `customer_app` / `whatsapp`, not a referral |

Observations
* The referrer is **always a technician** (`leads.owner_id → technicians.id`); never a customer or staff.
* `owner_id` is **overloaded**: "referrer" when `source='referral'`, "selling/finding technician" when `source='field'`
  (admitted in a `LeadBadges.tsx` comment). Today `field` leads can also earn finder credit.
* The referred party is a customer row on every sale/service/AMC path; the only exception is a technician enquiry.
* **No dedupe**: every referred sale/ticket/AMC inserts a new lead, so one customer referred twice has two leads; the
  customer page chip uses only the first.
* A **second, separate mechanism** exists for customer-to-customer referral: `referral_points` (ledger; awarded **manually**
  by staff from a won lead's panel via `award_referral_points`; redeemed in `create_sale` at
  `settings.referral_point_value`). There is no referral code/link anywhere; the referred lead is only in a free-text
  `reason`. It currently has 0 rows.

## 3. How the bonus is calculated and whether it is credited
* `incentive_type`: service_income, sales_income, review, **finder_credit**, installation. `reward_category` includes
  `highest_referral` (a non-monetary reward: ≥ 20 conversions and the month's maximum).
* `technician_finder_conversions(org, tech, period)` = distinct **completed tickets** (with a finished visit, in the IST
  month) whose lead is owned by the technician. It counts tickets, not referrals or customers, and does not distinguish
  `referral` from `field`; a 6-visit AMC can add up to six conversions over time.
* `compute_incentives` (master presses **Compute** in HR; no cron): for a `finder_credit` rule, if the month's conversions ≥
  `threshold` it inserts **one** `incentives_earned` row of `rule.amount` per technician per month. An existing
  (technician, rule, period) row is never revised, so a late completion in an already-computed month never raises it.
* `compute_salary` sums `incentives_earned` into `salaries.incentives`. There is no paid/credited flag on either table.
  So "credited" today only means "a row exists for that month and salary was recomputed".
* `technician_kpi_summary.total_referrals` counts completed referred **tickets** (all time), while the Referrals tab counts
  **leads** — the two numbers disagree by design.

## 4. What the screens show today
| Screen | Shows | Missing |
|---|---|---|
| Leads list / kanban chip (`LeadBadges.tsx`) | "Referred by X" (when `source='referral'`) else "Technician X" | referred customer is the row itself; no type, bonus, credited |
| Customer detail | one chip "Referred by X" (first referral lead only) | date, type, further referrals, bonus |
| Technician detail → Referrals tab | per `referral` lead: customer, mobile, date, lead status | source type (sale/AMC/service), bonus amount, credited; excludes `field` leads that still earn credit; no tickets |
| Technician detail → KPIs | `total_referrals` (tickets) | does not match the tab; no bonus |
| Technician app → Profile | count + list (customer, date) | status, bonus, credited |
| Lead panel (staff) | award points to a **referring customer** for a won lead | invisible afterwards except the wallet balance |
| HR → Incentives | rule type, threshold, amount, period per technician | no per-referral breakdown |

## 5. Proposal
**Principle:** make the referral an explicit, queryable record and make the bonus point at it — without changing how money
is computed unless you decide to.

### 5.1 What to show (one row per referral)
Referrer (technician) · Referred customer · Source (Sale / AMC / Service / Enquiry / On-site AMC) · Status (lead →
converted → ticket completed) · Referral date · **Bonus** (amount attributed) · **Credited** (yes with the month /
pending / no rule) · Credited date · link to the invoice / AMC contract / ticket.
Header per technician and month: "N completed referral tickets, threshold T, bonus ₹X, credited yes/no (computed on D)".

### 5.2 Data changes (additive, phased)
1. **Phase 1 — read model, no new writes:** a view `v_referral_events` derived from today's data (lead + its tickets;
   invoices/contracts via `ticket.invoice_id` / `ticket.contract_id`) and an RPC `referral_overview(technician, period)`
   returning rows + the monthly summary. Master/ops/sales staff and the technician's own rows only.
2. **Phase 2 — stamp the link:** `invoices.lead_id` and `amc_contracts.lead_id` (nullable FKs) written by `create_sale`,
   `sell_amc_plan`, `renew_amc_plan`, the complaint creator in the same place the lead is inserted; backfill from tickets.
   Free-text name matching in `renew_amc_plan` is replaced by a picker (customer app) and an explicit "unmatched" result.
3. **Phase 3 — bonus traceability:** `incentives_earned.source_ref jsonb` (the lead/ticket ids that made up the month's
   finder credit) and `credited_at`; `compute_incentives` writes it without changing the formula. If you want a payout
   flag, add `paid_at` on `salaries`/`incentives_earned` (no such concept exists today).
4. **Phase 4 (only if you decide to):** a real `referral_events` table (written at the same points) replacing the view.
Also: dedupe rule (one open referral per customer+technician) and a decision on `field` leads (see questions).

### 5.3 UI
Technician detail → Referrals tab and the technician app become a table with the columns in 5.1; customer detail shows a
"Referrals" list (all, not just the first); HR → Incentives expands a finder row into its contributing referrals; the leads
chip adds a type icon. i18n en + ta for all new labels.

### 5.4 Risks
* `owner_id` overload and `field` leads: deciding what counts changes displayed totals.
* Counting basis (tickets vs leads) will be shown side by side and visibly differ.
* The month-lock behaviour of `compute_incentives` (never revises a computed month) will become visible.
* `renew_amc_plan` name matching is ambiguous for duplicate names.
* Pay-related: the finder rule amount/threshold, any per-referral payout, and the credited/paid flag all need **master
  approval** and should be master-editable only.

### 5.5 Effort and impact on existing numbers
* Phase 1 view + RPC + UI list: **2–3 days**. All phases with write-path patches, backfill and tests: **4–6 days**.
* Existing numbers: **none change** in Phase 1. Every bonus shows ₹0 until a `finder_credit` rule is created in Masters →
  Incentive Rules (none exists). `total_referrals` and the tab count will be shown with their definitions.
* The test-customer flag (batch-2 §5) must exclude test customers from `technician_finder_conversions` and the referral
  view so test sales never earn or show a bonus.

## 6. Open questions (need your decision)
1. Is the finder bonus **per referral** or a **flat monthly amount** at a threshold (what the code does)? What amount and
   threshold? (no `finder_credit` rule exists)
2. Should a technician's **on-site AMC sale** count as a referral (it is `source='field'`, not `referral`)?
3. Should customer-to-customer referral points appear in the same list (referrer = customer)?
4. What does **credited** mean to you: "included in the month's salary computation", or "actually paid" (needs a paid flag
   and who sets it)?
5. Should the bonus be earned when the referred sale is **won**, or only when the referred **ticket is completed** (today)?
6. One referral per customer per technician (dedupe), or every sale/ticket counts?
7. Should the referral be recorded for invoices too (so "revenue from referrals" can be shown per technician — item 15)?
