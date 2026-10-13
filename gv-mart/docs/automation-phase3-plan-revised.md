# Automation Phase 3 (revised): Wave 1 flows, sender-side work, hand-off to the dispatcher

Status: PLAN ONLY (2026-10-12). No code, no migration written or applied, nothing sendable. Supersedes `docs/automation-phase3-outline.md`.
Inputs: the owner's 16 answers (memory note `gv-mart-automation-owner-answers-2026-10-12`), Phase 2 as applied live (migration `20261017100000`, dry-run only), the dispatcher v2 live-state handoff (`docs/dispatcher-live-state-handoff.md` on `docs/dispatcher-live-state-handoff`), branch `feat/dispatcher-v2` (migration `20261016330000` per-number scope, unapplied), branch `feat/wa-cron-pgnet` (migration `20261016200000`, unapplied), and the Wave 1 template sheet (branch `docs/automation-wave1-templates`).

Numbers are referred to only as "the test number ending 6740". No keys, tokens or message ids appear here.

## 0. What this plan relies on, and three corrections to earlier documents

1. **The dispatcher owns delivery.** Automation never calls Wasi. It hands finished work to the existing outbox; the dispatcher (insert-first, claim-before-send, template mapping, 24 h window logic, `delivery_status`) sends. (Section 3.)
2. **`appointment_reminder` is not an interim for "technician assigned".** The dispatcher handoff (item 8) says so and it asks the customer to "reply to confirm". The earlier outline suggested it as an interim; that is withdrawn. `ticket.assigned` waits for `gvm_technician_assigned`.
3. **Variable names.** The dispatcher resolves record values under its own keys (`ticket_ref`, `complaint`, `technician`, `slot`, ...) and maps them to Wasi's parameter names per template through `whatsapp_event_templates.param_map`. The template sheet's Wasi names (`customer_name`, `technician_name`, ...) therefore need no change; the mapping row bridges them. This must be checked per template after approval (`body_param_examples` keys).
4. **Phase 2 has two latent problems that must be fixed before any real send** (section 2, items S0a and S0b): dry-run rows count toward cooldown and max-fires, and a dry-run row consumes the idempotency key a live send would need.

## 1. First flows, in order

Gate for every flow (Q1): it goes live only after its template is approved, its mapping row exists, and its test-customer run (section 5) passed. Language comes from section 2 item S2.

| # | Event (emitter exists in Phase 2?) | Recipient | Template (EN / TA names) | Message class (Q12) | State of the template today | Extra work |
|---|---|---|---|---|---|---|
| 1 | `ticket.created` (yes) | customer | `gvm_service_booked_en` / `_ta` | job | to submit | none |
| 2 | `ticket.completed` (yes) | customer | `gvm_service_completed_en` / `_ta` | job | to submit; needs `<CUSTOMER_APP_URL>` button | none |
| 3 | `ticket.assigned` (yes) | customer | `gvm_technician_assigned_en` / `_ta` | job | to submit; needs `<CUSTOMER_APP_URL>` button | technician name and slot variables come from the dispatcher context (already built on `feat/dispatcher-v2`) |
| 4 | `invoice.issued` (yes) | customer | `gvm_invoice_issued_en` / `_ta` (text + app button); `invoice_document` only after a public invoice PDF URL exists | job (invoices exempt from the cap, Q12) | to submit | Q8: from the system; quotations stay manual |
| 5 | `amc.joined` (yes) | customer | `gvm_amc_welcome_en` / `_ta` | job | to submit | dispatcher needs a new ref type `amc_contract` and a context resolver |
| 6 | `feedback.requested` (no: scanner) | customer | `gvm_feedback_request_en` / `_ta` | **non-job** | to submit; risk of Marketing re-categorisation | SQL scanner with `p_now`: N hours after completion |
| 7 | `review.google_requested` (no: scanner) | customer | `gvm_google_review_en` / `_ta` | **non-job** | to submit; fixed button `<GOOGLE_REVIEW_URL>`; highest rejection risk | every completed service, no condition, no staff name, 90-day cooldown (S6); low rating raises an internal alert instead of changing who is asked |
| 8 | `amc.expiring` 30/15/7 (no: scanner) | customer | `gvm_amc_expiring_en` / `_ta` | **non-job** (renewal reminder) | to submit | SQL scanner; windows as rule settings; dispatcher ref type `amc_contract` |
| 9 | `amc.visit_scheduled` (no: emit call at the AMC visit generator) | customer | `gvm_amc_visit_scheduled_en` / `_ta` | job | to submit | one `automation_emit` call in the AMC visit creation path |
| 10 | `technician.on_the_way` (no emitter, no signal) | customer | `gvm_technician_on_the_way_en` / `_ta` | job (time-critical) | to submit; can be approved early | blocked on section 4A (Start travel) and 4B (database scheduler) |

Existing approved templates: `hello_world` (connectivity only, mapped as `test.hello`), `invoice_document` (blocked on a PDF URL), `shipping_update` (not for service events), `appointment_reminder` (not an interim, see 0.2).

Not in this phase: quotations by WhatsApp (Q8, manual until a template exists), staff WhatsApp (Q7, second wave), supplier flows (Q15), `technician.arrived` (template is Wave 2; the dispatcher handoff lists `gvm_technician_arrived` among templates to approve, so it can be pulled forward if the owner wants it).

## 2. Sender-side work (explicit items)

S0 is prerequisite hygiene; S1 to S7 are the owner's answers.

| ID | Item | What to build | Answer |
|---|---|---|---|
| S0a | Dry-run rows must not count | Cooldown, max-fires and idempotency lookups ignore queue rows in `dry_run` and `blocked_not_allowlisted` (Phase 2 counts them). Otherwise shadow-mode rows for real customers would block a real review request for 90 days. | hygiene |
| S0b | Idempotency key includes the delivery mode | Key becomes `rule_key|customer|subject|occurrence|<dry/live>` so a shadow row never suppresses the live send of the same occurrence; replay protection within each mode is unchanged. | hygiene |
| S1 | Lead with no owner goes to the master | Recipient resolver: `sales` role with `leads.assigned_to` null resolves to the organisation's active master(s); audited as `recipient_fallback`. Phase 2 currently audits `skipped_no_recipient`. Staff messages are in-app only in this phase (Q7), so this affects in-app delivery and the audit, not WhatsApp. | Q16 |
| S2 | `customers.preferred_language` | New nullable column (`en`/`ta`), UI field on the admin customer form and the customer app profile (en + ta strings), backfill from `profiles.language` where a login exists. Language order: `preferred_language`, then login language, then rule default, then `en`. The dispatcher's `customerLanguageAndName` reads it (small change on the dispatcher branch). | Q9 |
| S3 | STOP and STOP ALL | Webhook keyword recognition (English, Tamil `நிறுத்து`, common spellings; master-editable phrase list via the existing Bot Phrases mechanism) writes the opt-out record; one confirmation reply inside the 24 h window, then silence. New table `customer_comm_prefs` (org, customer, `opt_out_non_job`, `opt_out_all`, source, timestamps). `STOP` = non-job class only (feedback, review, renewal, promotions); job and invoice messages continue; `STOP ALL` = everything. Also an in-app/staff way to record and clear an opt-out. A resubscribe keyword (for example START) is proposed but was not asked for. | Q4 |
| S4 | Quiet hours 9 pm to 8 am IST | Engine computes `fire_at`: messages due inside the window are held until 8 am. Per-rule flag `respect_quiet_hours` (default true). Proposal to confirm: `technician.on_the_way` and OTP are time-critical and are not held. | Q12 |
| S5 | Daily cap of 3, non-job only | Message class per template/rule: `job` or `non_job` (column on the rule and seeded for each template, see the table below). The engine counts handed-over non-job messages per customer per IST day; job and invoice messages are never counted and never blocked. Over the cap: new decision `deferred_daily_cap`, re-queued for the next day's 8 am, expiring after 3 days. | Q12 |
| S6 | 90-day review cooldown | Review rule seeded with `dedupe_cooldown_hours = 2160`; counted per customer across all subjects, only for rows actually handed over (S0a). | Q3 |
| S7 | Main customer's mobile only | Recipient is `customers.mobile` for the subject's customer; `customer_members` numbers are never used; tested explicitly. | Q14 |

Message classification (seed, master-editable later):

| Class | Templates |
|---|---|
| job | `gvm_service_booked`, `gvm_technician_assigned`, `gvm_technician_on_the_way`, `gvm_technician_arrived`, `gvm_service_completed`, `gvm_invoice_issued`, `invoice_document`, `gvm_amc_welcome`, `gvm_amc_visit_scheduled`, `gvm_amc_visit_reminder`, OTP |
| non-job | `gvm_feedback_request`, `gvm_google_review`, `gvm_amc_expiring`, `gvm_amc_expired`, `gvm_amc_renewed`, `gvm_quotation_expiring`, any promotion |

Anything unclassified defaults to non-job (the safer side: capped and stoppable).

## 3. How automation hands rows to the dispatcher

Principle: one sender, one outbox. Automation produces `whatsapp_outbox` rows in `pending` and never talks to Wasi.

**Hand-off step** (new SQL function run by pg_cron every minute, service-role only; pure SQL, no HTTP):
1. Select queue rows that are due (`fire_at <= now`), state `queued`, belonging to a rule that is `live`, or `test_only` with a test subject.
2. Re-check, in this order, at hand-off time (not only at emit time): global switch; rule status; **dispatcher scope** (`wa_dispatch_v2_applies(org, mobile)`); F-08 test-mode allow-list; opt-out (S3); daily cap (S5); cooldown (S6); quiet hours (S4).
3. Insert one outbox row: `direction = 'outbound'`, `status = 'pending'`, `to_mobile` = the customer's main mobile (S7), `template` = the mapping key (the rule's template base, for example `gvm_service_booked`), `ref_type` / `ref_id` = the subject (`service_ticket`, `invoice`, later `amc_contract`), `customer_id`, and `payload` carrying `automation_queue_id` and `rule_key`.
4. Mark the queue row `handed_over` with `outbox_id` and write an audit row `handed_over`. Phase 2's CHECK that forbids deliverable queue states is relaxed in its own reviewed migration, only then.

**Template mapping and language:** the dispatcher resolves `whatsapp_event_templates(event_key, language) -> wasi_template_name + param_map` against the mirror `whatsapp_wasi_templates` (synced status `approved`). `_en` and `_ta` are separate names; the dispatcher selects by name. A missing or unapproved mapping becomes `skipped_no_template`, which is the correct, visible outcome and is never free-texted outside the 24 h window.

**Per-number scope (`wa_dispatch_v2_numbers`) and why the hand-off must check it:** with scope `numbers` and the list holding only the test number ending 6740, v2 applies only to that number. A recipient outside the list falls to the legacy path, which can send free text. Automation must therefore refuse to hand over any row whose number `wa_dispatch_v2_applies` is false for (audit `blocked_not_in_dispatch_scope`), so the new flows can never reach a real customer through the legacy path.

**Gates, outermost to innermost:** `automation_enabled` -> rule status (`test_only` | `live` | `paused`) -> dispatcher scope (`wa_dispatch_v2_enabled`, scope, numbers) -> F-08 test mode (allow-list) -> mapping `is_active` and template approved -> opt-out/cap/cooldown/quiet hours. Test subjects add the Phase 2 hard stop (a test subject can only reach a flagged test number).

**Initial configuration for the first flows (test number only):** `wa_dispatch_v2_enabled = true`, scope `numbers`, `wa_dispatch_v2_numbers = [test number]`; F-08 test mode ON with the same single number; every rule `test_only`; only the mapping rows of approved templates active.

**Switching one message type from test_only to live (Q1):**
1. Template approved, mirror synced, mapping row created with the right `param_map` (checked against `body_param_examples`), `is_active` set.
2. Run that flow's test-plan section 5 against the test customer; all checks green.
3. Shadow period: the rule is live in dry run alongside the old milestone trigger (no handover) and the decisions are compared per event for a short, agreed window.
4. Promotion: `automation_rule_save` creates the next rule version with status `live` (immutable history, `config_changed` audit row) **and** the legacy trigger for that event is switched off by a per-event cutover flag, in the same step (no double send).
5. Widen reach: still under scope `numbers`, add a small list of staff-owned numbers first; only then the organisation scope `org`, which is a separate, explicit owner decision because it applies to every dispatched ref type at once.
6. Roll back per message type: set the rule `paused` or deactivate its mapping; global stop is `automation_enabled = false`; v2 stop is the dispatcher flag.

## 4. Separate items

### 4A. "Start travel" button and departure signal

- **Scope:** a button on the technician's job detail screen (`JobDetailPage`) for an assigned job that has not started: "Start travel". Server side: new nullable `appointments.travel_started_at` (or `service_tickets.travel_started_at`), and an RPC `start_travel(ticket)` callable only by the assigned technician, only once per visit, only while the ticket is assigned, which stamps the time and calls `automation_emit('technician.on_the_way', ...)`. The catalogue event already exists; this adds its emitter. English and Tamil strings; the existing "arrived" visit-start flow is unchanged.
- **ETA variable:** the template needs `eta`. Proposal: a master setting for the default travel estimate (for example 30 minutes) at first; a computed estimate from the technician's last location and the customer address is a later improvement and is not assumed here.
- **Risks:** an accidental tap (mitigation: confirm dialog, and no second message on a repeat tap); technician forgets to tap (no message sent, which is the safe failure; "arrived" still works); message sent late if the scheduler lags (mitigation: stale-row rule, skip if older than 60 minutes); offline taps (queued client-side; the server stamps on arrival, so a stale tap is dropped by the same rule); permission leak (RPC is definer, revoked from PUBLIC/anon, checks technician-ticket ownership).
- **Test plan:** rolled-back SQL tests (assigned technician succeeds once; other technician, other role, anon refused; repeat tap is a no-op; wrong ticket status refused; emits exactly one event; no emit if automation is off); UI test of the button states; end-to-end with the test technician and test customer (one event, one audit row, one outbox row after the template is approved).

### 4B. Database scheduler (pg_cron + pg_net, migration `20261016200000`, unapplied on `feat/wa-cron-pgnet`)

- **Scope:** `wa_cron_invoke()` calls `wa-milestone-dispatch` and `wa-scheduled-tasks` through pg_net every 5 minutes from pg_cron; secret in Vault (`wa_cron_secret`), created by the operator, not in git. After a verified run the GitHub `schedule:` blocks are removed (manual dispatch stays). The automation hand-off function (section 3) and the SQL scanners run on the same pg_cron.
- **Why it matters:** GitHub's `*/5` has been firing every 3 to 7 hours; "technician on the way" and quiet-hour release are useless on that clock (Q13).
- **Risks:** enabling it before the dispatcher sends templates only sends free text faster (its own header says so), so it is applied after the dispatcher flag is on and tested; missing Vault secret makes the call raise (visible in `cron.job_run_details`, by design); `pg_net` response table growth (needs a periodic cleanup); double triggering with GitHub while both exist (harmless, the functions pace themselves per org); an extension install on the production project; the 15 s function timeout versus pg_net's own timeout.
- **Test plan:** rolled-back apply on the live schema to check the SQL; after approval apply, create the secret, observe two consecutive scheduled runs in `cron.job_run_details` and `net._http_response`, confirm no duplicate sends (outbox unchanged for the test run), then remove the GitHub schedule and watch one cycle; the cron dead-man alert (`cron_job_stale`) must clear.

## 5. Test plan (flagged test customer and the test number ending 6740 only)

Fixtures (approved write, Q10/Q11): the flagged customer "jeshee test trigger", a dedicated test technician and a test sales person, all marked test; the test number is not also a supplier (a past collision made the supplier path win); allow-list and `wa_dispatch_v2_numbers` hold only that number; every rule `test_only`.

Checks for every flow (the columns of the table below are all asserted, not just "a message arrived"):
1. one `automation_event_log` row for the emit;
2. one `automation_audit` row `handed_over` for the rule, none `skipped_*` unexpectedly;
3. exactly one `whatsapp_outbox` row, `to_mobile` last four digits 6740, `status` moves `pending` to `sent`, `template_name` equals the mapped `_en`/`_ta` name, `template_params` equal the expected variables with no empty value, `wa_message_id` set from `meta_message_id`;
4. `delivery_status` reaches `sent` then `delivered` (and `read` if opened) from the webhook;
5. no other outbox rows, no row for any other number, no other customer, lead, ticket or invoice changed (before/after counts and the real-organisation lead hashes), and no report or KPI changed.

| Flow | How it is fired (test customer) | Template expected | Extra checks |
|---|---|---|---|
| 1 `ticket.created` | book a service through the app | `gvm_service_booked_en` (`_ta` for a Tamil-preference customer) | re-fire the same ticket: `skipped_duplicate`, no second row |
| 2 `ticket.completed` | complete the visit with the OTP | `gvm_service_completed_*` | button URL shows on the handset |
| 3 `ticket.assigned` | auto-assign to the test technician | `gvm_technician_assigned_*` | technician name and slot correct; flip the status back and forth: still one message |
| 4 `invoice.issued` | service-only test sale | `gvm_invoice_issued_*` | amount and date correct; no stock movement; job class: not counted in the cap |
| 5 `amc.joined` | sell a plan to the test customer | `gvm_amc_welcome_*` | main mobile only: add a family member with a different number, no message to it |
| 6 `feedback.requested` | scanner with `p_now` after completion | `gvm_feedback_request_*` | counted toward the daily cap |
| 7 `review.google_requested` | scanner after completion | `gvm_google_review_*` | sent regardless of rating (rating 5 and rating 2 give the same result); no staff name anywhere; a second completion inside 90 days: `skipped_cooldown` |
| 8 `amc.expiring` | scanner at T-30, T-15, T-7 | `gvm_amc_expiring_*` | exactly one per window; replay adds none |
| 9 `amc.visit_scheduled` | create an AMC visit | `gvm_amc_visit_scheduled_*` | none |
| 10 `technician.on_the_way` | "Start travel" by the test technician | `gvm_technician_on_the_way_*` | one message per visit; repeat tap adds none; stale-row rule |

Cross-cutting checks: STOP (non-job blocked, job and invoice continue) and STOP ALL (everything blocked), one confirmation reply only; fourth non-job message in a day deferred while job and invoice messages still go; inside quiet hours held until 8 am IST; recipient outside `wa_dispatch_v2_numbers` refused with `blocked_not_in_dispatch_scope`; dispatcher flag off or `automation_enabled = false` stops hand-over; missing template gives `skipped_no_template`; lead with no owner resolves to the master; customer with `preferred_language = ta` gets the `_ta` name and one with it empty gets `_en`.

## 6. Dependencies

| Item | Blocked on | Build now? |
|---|---|---|
| S0a, S0b (dry-run hygiene) | nothing | **Yes** |
| S1 master fallback | nothing | **Yes** |
| S2 `preferred_language` (column, UI, backfill) | nothing for the build; dispatcher reads it later | **Yes** (UI strings need a Tamil check) |
| S3 STOP / STOP ALL recognition and opt-out record | nothing for the build (confirmation reply is free text inside the window) | **Yes** |
| S4 quiet hours, S5 cap and classification, S6 cooldown, S7 main mobile | nothing | **Yes** |
| Hand-off function and relaxed queue states (section 3) | dispatcher v2 deployed and the per-number scope migration applied | **Yes, in rolled-back tests**; apply after the dispatcher |
| Mapping rows for Wave 1 templates | the exact approved names and `body_param_examples` keys | Seed inactive; activate after approval |
| SQL scanners (`amc.expiring`, feedback, review) and the AMC visit emit | nothing (dry-run) | **Yes** |
| Dispatcher: new ref types `amc_contract`, context resolvers, `preferred_language` read | dispatcher owner | Needed for flows 5, 8, 9 |
| 4A Start travel (RPC, button, strings) | nothing for the build; strings need Tamil check | **Yes** |
| 4B database scheduler | dispatcher flag ON and tested; Vault secret | Build exists; apply later |
| Any real or test send of a `gvm_*` template | Wasi/Meta approval of that template | **No** |
| Tamil sends (`_ta`) | Tamil review (`docs/tamil-review-wasi-templates.md`) | **No** |
| Templates with a button (assigned, completed, feedback, invoice, review) | `<CUSTOMER_APP_URL>` and `<GOOGLE_REVIEW_URL>` | Submission blocked; code is not |
| `invoice_document` path | a public invoice PDF URL (no generator exists) | **No**; text template is the stop-gap |
| Org-wide scope (`wa_dispatch_v2_scope = org`) | owner decision after the test-number phase | **No** |

## 7. Open points to confirm

- Quiet hours: should `technician.on_the_way` and OTP be exempt (proposed)?
- Daily cap overflow: defer to the next day (proposed) or drop?
- Master fallback: all active masters or one named master?
- A resubscribe keyword (START) after STOP: wanted?
- `gvm_technician_arrived` in Wave 1 (the dispatcher handoff lists it) or stay in Wave 2?
