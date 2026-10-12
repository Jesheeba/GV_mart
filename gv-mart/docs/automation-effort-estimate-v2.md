# Automation: effort estimate v2 (2026-10-12)

Status: DOCUMENT ONLY. Replaces the effort section (section 13) of `docs/plan-automation-flows.md`. Unit: working days of one developer, including live verification, excluding waiting time on Meta, Wasi and the owner. Ranges, not commitments.

## 1. What changed since the first estimate

1. **Every customer message outside the 24-hour window must be an approved template.** The first estimate assumed free text with templates as a "Phase 0 submission chore". Now no flow can go live until its template (English and Tamil, each a separate name) is approved.
2. **Templates are submitted by hand in the Wasi dashboard** (no API), Tamil needs a native review first, and Meta reviews can take from minutes to days. The calendar time is dominated by waiting, not coding.
3. **The first estimate's own arithmetic.** Its phase table sums to about 22 to 30 working days (4-5 + 4-6 + 2-3 + 5-6 + 4-5 + 2-3, plus Phase 0), but its text says "roughly 3-4 weeks". The honest reading is 4 to 6 calendar weeks of focused work. This version keeps the sum, not the summary line.
4. **Wave 1 is smaller than the full design** (11 names, 22 submissions of 32 names, 64 submissions; `gvm_technician_arrived` was added to Wave 1 on 2026-10-12) and ships first; later waves are an extension.

## 2. Prerequisite (not part of this estimate)

The dispatcher fix is planned in a separate document, `docs/plan-dispatcher-fix.md` (branch `docs/dispatcher-fix-plan`), and is a **prerequisite**, not part of this one. In short: insert the outbox row first; store the WhatsApp message id from `meta_message_id`; `status` becomes `sent` only after Wasi confirms; delivery receipts go into a separate `delivery_status`; claim-before-send; template payloads. Its effort is estimated there and is **not** included in any number below. That plan also waits for the security branch (`fix/staff-security-review`, the F-08 block in `sendMessage`) to reach `origin/main`.

Nothing in phases 2 to 6 may be switched on in production before the prerequisite is deployed.

## 2a. Scope change: Google review policy (April 2026)

Removed from the design and from every phase below: any technician incentive per Google review, any review target or quota, and the technician review input box. Replaced by: ask every customer after a completed service by one WhatsApp message (no staff name, no reward), offer the QR code on the technician's phone without pushing, and record reviews for reporting only. Effort effect: slightly lower (no incentive rule, no technician input box, no incentive filter for review events); the numbers below were not reduced, so this saving is treated as contingency.

## 3. Phases that can ship independently

| Phase | What ships | Effort (working days) | Depends on | Blocked on owner? |
|---|---|---|---|---|
| **0. Dispatcher fix** (separate plan) | Honest send status, delivery tracking, template sending | not estimated here | security branch on `origin/main` | No |
| **1. Template readiness** | Wave 1 submission sheet used; 11 templates (22 submissions) created in Wasi; approval tracked; template mirror synced; one approved template sent to the test number ending 6740 | 2 to 3 | Phase 0 (for the real send) | **Yes**: owner submits templates; Tamil review; app and Google URLs confirmed |
| **2. Foundation** | `automation_emit`, rules and queue tables, append-only audit table, kill switches, opt-out table and STOP handling, allow-list and test-send guard inside `sendMessage`, template resolution gates | 5 to 7 | Phase 0; answers to questions 3, 4, 12 | Partly (answers); build itself is not blocked |
| **3. Wave 1 flows** | Booked, assigned, arrived, completed, invoice issued, feedback, Google review, AMC welcome, AMC visit scheduled, AMC expiring (on the way after the departure signal). Old triggers re-pointed behind a per-event cutover flag, shadow mode, then switch | 6 to 8 | Phases 1 and 2; templates approved | **Yes**: approved templates; questions 2, 5, 6, 9 |
| **4. Test fixtures and harness** | Flagged test customer, test technician and sales person, `is_test` filters on reports/KPIs/incentives, CI guard, table-driven end-to-end runner, results document | 4 to 6 | Phase 2; question 10, 11; owner approval of the live fixture writes | **Yes**: fixtures approval |
| **5. Master flow builder UI** | Triggers tab, rule editor, simulate, audit view, global bar, English and Tamil labels | 5 to 7 | Phase 2 (rules model); Phase 3 for real data | No (Tamil UI labels need a review pass) |
| **6. Remaining waves and videos** | Waves 2 and 3 (22 names, 44 submissions), keyword-flow videos, staff WhatsApp, payment, warranty, rental, referral scanners | 8 to 12 | Phases 2 to 5; submissions and Tamil review per wave | **Yes**: further submissions and review |
| **Total (phases 1 to 6)** | | **30 to 43** | | |

Phases can overlap: while templates are in Meta review (Phase 1 wait), Phase 2 can be built. Phase 3 cannot go live until templates are approved, but its code can be finished and shadow-tested with `skipped_no_approved_template` as the expected result.

### Per-phase detail

**Phase 1: template readiness.**
- Ships: approved templates, mirror, one verified test send.
- Risks: Meta re-categorises feedback or Google review to Marketing; Tamil review slips; a rejected template needs rewording and a new name; Wasi's `body_param_examples` keys differ from the sheet's names.
- Tests: send each approved template once to the test number only; compare variable keys from `GET /api/v1/templates` with the sheet; confirm the button URL on the handset.

**Phase 2: foundation.**
- Ships: engine with no flows enabled (nothing changes for customers).
- Risks: `sendMessage` and `whatsapp_outbox` are touched by both the security branch and the dispatcher fix, so merge order matters; `audit` table must be immutable even for the service role.
- Tests: audit update/delete raises; idempotent replay; kill switch holds the queue; allow-list blocks a non-test number without retrying; opt-out classes behave per question 4.

**Phase 3: Wave 1 flows.**
- Ships: customer-visible messages for the service lifecycle, invoice, AMC and feedback/review, with the old plain-text sends retired per event.
- Risks: double sending during the cutover (old trigger plus new engine); "on the way" blocked until the departure signal exists; GitHub cron drift makes delays unreliable until question 13 is settled; no invoice PDF generator exists, so `invoice_document` stays unused.
- Tests: the Wave 1 rows of the end-to-end table (section 5); per-event parity check in shadow mode before cutover.

**Phase 4: test fixtures and harness.**
- Ships: safe, repeatable testing and the report-exclusion audit.
- Risks: the exhaustive filter audit of every report and KPI is the largest hidden cost; a missed report silently counts test data.
- Tests: before and after dashboard snapshots identical; a guard test fails if a report function ignores `is_test`.

**Phase 5: builder UI.**
- Ships: master can edit rules without a developer.
- Risks: scope creep into free-form conditions; the design keeps typed filters only.
- Tests: simulate button shows the same decisions as a real run; edits create new immutable versions.

**Phase 6: remaining waves.**
- Ships: everything in the 32-name catalogue the owner still wants.
- Risks: each wave repeats the submission and review wait; supplier flows stay out unless question 15 changes.
- Tests: the matching rows of the end-to-end table.

## 4. What is blocked on the owner and what is not

| Blocked on the owner | Why |
|---|---|
| Template submission in the Wasi dashboard (22 for Wave 1, 42 more later) | Dashboard only, no API |
| Tamil review of every `_ta` text | Submission waits for it (`docs/tamil-review-wasi-templates.md`) |
| The two fixed URLs: customer app link and Google review link | Needed inside the templates; cannot be invented |
| Answers to the 16 questions (`docs/automation-open-questions-plain.md`) | Questions 2, 3, 4, 5, 6, 9, 12 gate Phase 2 and 3 design |
| Approval of the live test-fixture writes (test customer flag, allow-list row, test staff) | A live write; not done until approved |

| Not blocked | |
|---|---|
| Phase 0 (dispatcher fix), as soon as the security branch is on `origin/main` | Separate plan |
| Phase 2 foundation and Phase 5 UI skeleton | Engine and builder work without approved templates |
| Writing code for Phase 3 flows (it cannot go live) | Shadow mode and `skipped_no_approved_template` prove the wiring |

## 5. End-to-end test plan (test customer and test number only)

Rules for every test: the only customer used is the flagged "jeshee test trigger" (the test number ending 6740); real WhatsApp goes only to that number; `send_mode = allowlist_only` with that single number on the allow-list; staff recipients use the test technician and test sales person with the recipient override pointing at the test number; all new rules start as test-only. Nothing is fired by inserting audit rows by hand.

**Preconditions**
1. Phase 0 deployed; Phase 2 deployed; flagged test customer, test technician and test sales person exist (approved write).
2. The test number is not also registered as a supplier (a past collision made the supplier check win silently).
3. The relevant templates are approved. If one is not, the expected and passing result is `skipped_no_approved_template`.

**Wave 1 firing table**

| Step | How it is fired (as the test customer) | Expected |
|---|---|---|
| 1 | Book a service via the app | `ticket.created`: one booked message (EN or TA by the customer's language) to the test number; audit `queued` then `sent` |
| 2 | Auto-assign to the test technician | `ticket.assigned`: one customer message with the technician name and slot; technician row routed to the test number by override |
| 2b | Technician starts the visit (visit row created) | `technician.arrived`: one customer message (`gvm_technician_arrived_*`), job class, not capped |
| 3 | Technician starts travel (when the action exists) | `technician.on_the_way`: one message; none emitted by visit start |
| 4 | Complete the visit with the OTP | `ticket.completed`: one completed message |
| 5 | Feedback request after the configured delay | `feedback.requested`: one message, only once |
| 6 | Google review rule after the configured delay | `review.google_requested`: one message with the fixed Google button; no reward, staff-name or rating wording; sent regardless of any rating; the same result with a rating of 5 and a rating of 2; no technician incentive, target or quota is created or changed by the review flow |
| 7 | Create a service-only test sale | `invoice.issued`: one invoice message; no stock movement |
| 8 | Sell an AMC plan | `amc.joined`: one welcome message |
| 9 | Create an AMC visit | `amc.visit_scheduled`: one message |
| 10 | Run the AMC scanner with simulated dates at 30, 15 and 7 days before expiry | `amc.expiring`: exactly one message per window; a second run of the same day adds none |

**Cross-cutting checks**
- Re-fire the same event: `skipped_duplicate`, no second send.
- Opt out via STOP, then fire a utility and a marketing-class message: behaves per the answer to question 4; one confirmation reply only.
- Send to a number not on the allow-list (throwaway rule, non-test subject): `blocked_not_allowlisted`, nothing sent, not retried.
- Global kill switch on mid-queue: rows held, no sends; switching back drains them.
- Rule paused after queueing: skipped at dispatch.
- Template missing for a language: `skipped_no_approved_template`, not free-texted outside the window.
- Quiet hours: held until 8 am IST then sent.
- Provider 409 for each code in the sheet's section 2: row `failed`, raw code stored, no retry except `conflict` once.
- Audit rows cannot be updated or deleted, even as the service role.
- Test isolation: dashboard and report snapshots before and after are identical; the test sale produced no incentive, rating or revenue figure.

**Exit criteria:** every row above observed with the expected audit rows; zero messages to any number other than the test number (checked from audit and outbox, masked numbers only); the owner confirms the count and wording on the single test handset; results written to `docs/automation-test-results.md` with masked numbers only.

## 6. Overall timeline reading

- Development effort for Wave 1 only (phases 1 to 4): about 17 to 24 working days after the dispatcher fix.
- With phases 5 and 6, about 30 to 43 working days.
- Calendar time depends on the owner: template submission and Meta review for Wave 1 should start the same day the sheet is accepted, because Phase 2 can run in parallel and Phase 3 cannot go live without approvals.
