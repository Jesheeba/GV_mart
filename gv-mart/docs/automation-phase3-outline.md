# Automation Phase 3 outline: Wave 1 flows (read-only outline, 2026-10-12)

**Superseded by docs/automation-phase3-plan-revised.md (2026-10-12), which includes the owner answers.**

Status: OUTLINE ONLY. No code, no migration, no apply, nothing sendable. Phase 2 (migration `20261017100000`) is built and tested but not applied; apply is on hold until the dispatcher track finishes.

Sources: Phase 2 migration and its tests; `docs/wasi-template-submission-sheet-wave1.md` and `docs/automation-effort-estimate-v2.md` (branch `docs/automation-wave1-templates`); `docs/plan-dispatcher-fix.md` (branch `docs/dispatcher-fix-plan`).

## 0. What Phase 3 is

Phase 2 records every event and decides what WOULD happen in a dry run. Phase 3 turns the Wave 1 events into real flows: a master-visible rule per event and recipient, a template, and a sender that actually delivers, in shadow mode first, then cut over per event.

Prerequisites (not Phase 3 work): the dispatcher fix (insert first, `meta_message_id`, claim-before-send, `delivery_status`, template payloads) is deployed; Phase 2 is applied; the test customer and test staff fixtures exist.

## 1. Which events become flows first

| Order | Event | Emitter today (Phase 2) | Recipient | Needs |
|---|---|---|---|---|
| 1 | `ticket.created` | Yes (ticket INSERT) | customer | template `gvm_service_booked` |
| 2 | `ticket.completed` | Yes (status to completed) | customer | template `gvm_service_completed` |
| 3 | `ticket.assigned` | Yes (status to assigned) | customer | interim `appointment_reminder`; target `gvm_technician_assigned` |
| 4 | `invoice.issued` | Yes (invoice INSERT) | customer | target `gvm_invoice_issued`; `invoice_document` once a public PDF URL exists |
| 5 | `amc.joined` | Yes (AMC contract INSERT) | customer | `gvm_amc_welcome` |
| 6 | `amc.visit_scheduled` | **No emitter** (visit ticket creation not hooked) | customer | `gvm_amc_visit_scheduled`; new emit call at the AMC visit generator |
| 7 | `amc.expiring` | **No emitter** (today a TypeScript scanner sends plain text) | customer | `gvm_amc_expiring`; SQL scanner with `p_now`, windows 30/15/7 as rule settings |
| 8 | `feedback.requested` | **No emitter** (TS scanner, plain text) | customer | `gvm_feedback_request`; scanner N hours after completion |
| 9 | `review.google_requested` | **No emitter** | customer | `gvm_google_review`; scanner after completion; every customer, no rating condition, no staff name, no incentive or quota |
| 10 | `technician.on_the_way` | **No emitter, and no departure signal exists** | customer | `gvm_technician_on_the_way`; blocked until a "Start travel" action (or an agreed rule) exists. `technician.arrived` is emitted but its template is Wave 2 |

Items 1 to 5 can go first because their events already exist as emit calls and need only a template and the sender. Items 6 to 9 need a scanner or a new emit call (small, SQL, `p_now` parameter). Item 10 is blocked on a product decision (open question 2).

## 2. Templates: what exists today vs what is new

Already approved on the account (named variables, Wasi picks by name):

| Template | Variables | Usable for | Fit |
|---|---|---|---|
| `hello_world` | none | Connectivity and the first end-to-end send to the test number ending 6740 only | Test only, never a customer flow |
| `appointment_reminder` | `customer_name`, `appointment_time` | `ticket.assigned` interim; later `amc.visit_reminder` | Imperfect: it asks the customer to reply to confirm and has no technician name or ticket reference; nothing handles the reply |
| `invoice_document` | `customer_name`, `invoice_number`, `invoice_date`, PDF header | `invoice.issued` | Good fit, **blocked**: needs a public invoice PDF URL and no invoice PDF generator exists in the repo |
| `shipping_update` | `name` | Nothing | Wrong: it says an order is out for delivery. Do not use for service visits |

Need the new Wave 1 templates (English `_en` and Tamil `_ta`, each its own name, Utility, submitted from the sheet):
`gvm_service_booked`, `gvm_technician_assigned`, `gvm_technician_on_the_way`, `gvm_service_completed`, `gvm_feedback_request`, `gvm_google_review`, `gvm_invoice_issued`, `gvm_amc_welcome`, `gvm_amc_visit_scheduled`, `gvm_amc_expiring`.

## 3. What is blocked, and by whom

| Blocker | Blocks | Owner |
|---|---|---|
| Wasi template approval (dashboard submission, Meta review) | Every flow except the interim `ticket.assigned` via `appointment_reminder`; without approval the correct result is `skipped_no_template` | Owner submits; Meta reviews |
| Tamil review of all `_ta` strings (`docs/tamil-review-wasi-templates.md`) | All Tamil sends; English can go first with `en` as the default language | Tamil reviewer |
| `<CUSTOMER_APP_URL>` and `<GOOGLE_REVIEW_URL>` confirmed | `gvm_technician_assigned`, `gvm_service_completed`, `gvm_feedback_request`, `gvm_invoice_issued`, `gvm_google_review` (fixed URL buttons) | Owner |
| Departure signal ("Start travel") | `technician.on_the_way` | Owner decision (question 2) + small app change |
| Public invoice PDF URL | `invoice_document` path (text template `gvm_invoice_issued` is the stop-gap) | Build |
| Dispatcher fix deployed | Any real send at all | Dispatcher track (separate plan) |
| Answers to open questions 3, 4, 5, 6, 9, 12 | Cooldowns, opt-out scope, review audience, customer-event defaults, language, quiet hours/daily cap | Owner (defaults pre-filled; accepted for now) |
| Template category outcome | If Meta re-categorises feedback or Google review to Marketing, `consent_required` appears and those two need opt-in or are dropped | Meta / owner |

## 4. Phase 3 work items (outline)

1. **Rules:** seed one `test_only` rule per Wave 1 event/recipient with the template name and language; master edits through `automation_rule_save` (no live status until promotion).
2. **Template mirror and language:** resolve `<base>_en` / `<base>_ta` by name from the customer's language (`profiles.language`, else rule default, else `en`); validate variable keys against the approved template before sending.
3. **Engine to sender:** the engine's `dry_run` queue state gains deliverable states in a later migration; the dispatcher claims queue rows (claim-before-send) and uses the fixed `sendMessage` path. Phase 2's CHECK that forbids deliverable states is relaxed only then, in its own reviewed migration.
4. **Scanners:** SQL scanners with `p_now` for `amc.expiring`, `feedback.requested`, `review.google_requested` (and the AMC visit emit); cron via pg_cron (HTTP dispatch stays on the existing path or the held pg_net branch, see open question 13).
5. **Shadow mode, then cutover per event:** the old milestone triggers and TypeScript scanners keep sending until the engine's dry-run decisions match them for that event; then a per-event switch retires the old path (no double sends).
6. **Test plan:** the Wave 1 firing table in `docs/automation-effort-estimate-v2.md` section 5, using only the flagged test customer and the allow-list with the test number ending 6740.

## 5. Suggested order of work

1. Template submission starts now (does not depend on code): English batches 1 to 3 from the sheet; Tamil after review.
2. Apply Phase 2 when the dispatcher track is done.
3. First flow end to end: `ticket.created` to `gvm_service_booked_en` for the test customer only (needs only one approved template).
4. Then `ticket.completed`, `ticket.assigned`, `invoice.issued`, `amc.joined`.
5. Scanners and the review/feedback pair last, because they carry the highest template-rejection risk and the scanner work.

Rough effort: 6 to 8 working days of build for the whole phase (estimate v2), excluding template approval and Tamil review time.
