# Plan: master-configurable automation flows (design only, 2026-10-12)

Status: DESIGN ONLY. No code, no DB writes, no WhatsApp sends were done. Waiting for answers (section 14) and approval of the test-customer proposal (section 15).

> **Amendment 2026-10-12 (Google policy, April 2026 update).** Reviews: no staff name or content-specific request, no quota or target, no payment or discount, no selective soliciting, no pressure on the premises. Applied below: the review request goes to every customer after a completed service (no rating condition, no technician name), the QR code on the technician's phone is offered not pushed, **any technician incentive or target tied to Google reviews is removed**, and reviews are recorded for reporting only. Where this amendment conflicts with older text in sections 2, 3.3, 9, 11 and 12, the amendment wins. Template names in 9.2 also need the `_en`/`_ta` suffix and named variables, see `wasi-template-submission-sheet-wave1.md`.

Standing rule applied throughout: the only real-organisation record any test may touch is the single test customer "jeshee test trigger" (Sirah Digital, Pallavaram, mobile ending 6740). Real WhatsApp in tests goes only to that number. This doc never prints the full number.

## 0. Limits of this investigation

- **Live DB was not queried.** Everything below comes from migrations, Edge Functions and `src/`. The live schema may differ (the batch-17 plan already noted `main` lags the parallel lead branches and the `.env` PAT returned 401).
- **The lead stack lives on parallel branches**, not `main` (`feat/sales-person-round-robin`, `feat/no-followup-tab`, `fix/reports-sql-aggregation`). Lead-event hooks and the report filters in section 10 must be built on the merged stack.
- **Wasi 409 is undiagnosed.** I did not probe it (no sends allowed in this phase). The design treats it as "provider rejected" and records the raw response; see section 9.
- Names of events/templates below are proposals. Nothing in this doc exists yet unless section 2 says so.

## 1. Summary

Today there are four hard-wired SQL triggers and three hard-coded Edge Function jobs that send WhatsApp. Wording, timing (30/15/7 days, 25 h lookback), recipients and "who gets what" are in code. There is no per-event kill switch, no opt-out, no append-only audit, no test-customer concept, and no template/24-hour-window awareness.

Proposal: one **event bus + rule engine**.

1. Every business event calls one SQL function, `automation_emit(event_key, subject, payload)`. Thin triggers/RPC hooks and scheduled scanners are the only emitters.
2. A master-edited **rule** per (event, recipient role) decides: template, language, media/link, delay, conditions, dedupe, opt-out handling, kill switch, status (test-only / live / paused).
3. A single dispatcher applies the same ordered gate checks to every send and writes **append-only audit rows** for every decision, including skips and blocks.
4. The only code that can talk to Wasi stays `sendMessage()` in `_shared/whatsapp.ts`. The allow-list and global kill switch are enforced inside it, so the bot, cron jobs, supplier RFQs and the new engine are all covered.

## 2. What exists today (verified in code)

| Area | Reality | Where |
|---|---|---|
| Send choke point | `sendMessage()` -> `sendViaWasi()`; text, interactive, and an UNCONFIRMED `templateSend` shape | `supabase/functions/_shared/whatsapp.ts` |
| Outbox | `whatsapp_outbox` (log + queue in one table), mutable (`retried_at`, `retry_count`), staff INSERT policy | `20260702170000`, `20260825140000`, `20260908100000` |
| Milestone triggers | `_milestone_ticket_notify` (booked/assigned/completed), `_milestone_visit_notify` ("on_the_way"), `_milestone_invoice_notify` insert outbox rows with `status='sent'` before anything is sent | `20260819170000` |
| Dispatcher | `wa-milestone-dispatch` (GH Actions cron) + `wa-dispatch-now` scan outbox rows by `ref_type` and send; skip rows with no template body; max 3 attempts | `_shared/wa-milestone-dispatch-core.ts` |
| Scheduled jobs | AMC 30/15/7 reminders, feedback request after completion, failed-send retry, monthly RFQ, rental billing, PO escalation, tier promotion | `wa-scheduled-tasks/index.ts` |
| Keyword flows | `automation_flows`: enquiry topic -> send video / quotation / link, `is_active` per row | `20260701090900`, `simulate_inbound_whatsapp` |
| Templates | `whatsapp_templates` (name, category, approval_status, body, variable_map). Local wording substitution only, not Meta submission | `20260819170000` |
| Kill switch | `settings.whatsapp_bot_enabled` (bot only; does not stop milestone/scheduled sends) | same |
| In-app notifications | `notifications` table, many types, plus `lead_notification_log` dedupe + pg_cron every 5 min for lead follow-ups | `20261007120000` |
| Customer language | `profiles.language` en/ta exists; `customers` has no language or opt-out column | `20260701090100` |

### Gaps and defects found while inventorying (each needs a decision)

1. **"on the way" is mis-labelled.** `_milestone_visit_notify` fires on `service_visits` INSERT, which is visit start (arrival). `src/lib/tracking/stages.ts` confirms there is no departure signal anywhere. A real "technician is on the way" event does not exist until the technician app gets a depart action (or we accept GPS-derived).
2. **Optimistic `status='sent'`.** SQL triggers write the outbox row as `sent` before dispatch; the real outcome lives on a second row. Counting "sent" from the outbox over-counts.
3. **Dedupe is weak and inconsistent.** Scheduled jobs dedupe by a 25 h outbox lookback; triggers do not dedupe at all (a status flip-flop re-notifies).
4. **No opt-out anywhere.** No `opt_out`/`do_not_contact` column or STOP keyword handling.
5. **No template/24 h awareness.** All sends are free text. Per the 2026-09-03 investigation and the 2026-08-27 incident, Wasi rejects outside the 24 h session window server-side, so many "sent" outbox rows may have been rejected. This is likely related to the 409s.
6. **Google review link is not in any message.** `settings.google_review_url` exists (only the in-app rating screen uses it); `feedback_request` is plain text with no link.
7. **No WhatsApp for**: lead stage changes, quotation sent/expiring, warranty start/expiry, AMC joined/visit scheduled/visit reminder/expired/renewed, ticket cancelled/rescheduled, payment due/overdue, post-service call, rentals, referral points. (Search found no sender; verify against live before building.)
8. **Staff recipients are in-app only**, role-addressed or per-user; no WhatsApp to technician/sales/master.
9. **Hard-coded constants** to move into rules: `AMC_REMINDER_WINDOWS = [30,15,7]`, `DEDUPE_LOOKBACK_HOURS = 25`, feedback body text, AMC body text.
10. **Review-gating risk** (policy, not code): the v2.2 spec shows the Google-review button only for 4.5-5 stars. Google's review policy prohibits selectively soliciting only happy customers. Flagged in section 12.

## 3. Event catalogue

Recipient legend: **C** customer, **T** assigned technician, **S** sales person (lead owner), **M** master, **O** operations admin, **SU** supplier. "Source" is where the emitter hooks in. "New" = no emitter today. Channel: WA = WhatsApp, IA = in-app notification (already exists unless "New").

### 3.1 Leads and enquiries

| Key | Event | Source | Recipients (default) | Notes |
|---|---|---|---|---|
| lead.created | Lead created, any source (walk-in, app, WhatsApp, field, referral) | `leads` INSERT; `_whatsapp_lead_upsert`, `submit_customer_enquiry`, `generate_enquiry_lead` | S (WA+IA), M (IA, exists), C (WA ack) | S = owner after round-robin; ordering matters (see 13) |
| lead.assigned | Owner set / changed | `leads.owner_id` change | S | New; round-robin branch |
| lead.stage.contacted | Stage -> contacted | `_lead_apply_status` / `_trg_lead_status_history` | C (optional), S | One key per stage so each is a separate rule |
| lead.stage.quoted | Stage -> quoted | same | C | pairs with quotation.sent |
| lead.stage.won | Stage -> won | same | C (thank-you), S, M | |
| lead.stage.lost | Stage -> lost | same | S, M (IA) | C default off (rule exists, disabled) |
| lead.reopened | Reopened with reason | `reopen_lead` | S | |
| lead.followup.due | Exact-time callback reminder | `run_lead_followup_notifications` | S (IA exists) | WA optional |
| lead.followup.overdue | Overdue > 24 h | same | S, M | |
| lead.stuck | Consecutive postpones | `postpone_count` | S, M | |
| callback.requested | Customer asked for callback | `request_callback` | S, M (IA exists), C (ack) | |
| product_enquiry.submitted | Product enquiry from app | `submit_customer_enquiry` (kind product) | C (ack + optional video), S | |
| spare_enquiry.submitted | Spare enquiry (app or WA) | `submit_customer_enquiry` / `wa_create_spare_enquiry` | C (ack), S/O | |
| enquiry.keyword_flow | Keyword matched an `automation_flows` row | `simulate_inbound_whatsapp` / webhook | C (video/link) | Migrate `automation_flows` into rules |

### 3.2 Quotations, sales, invoices

| Key | Event | Source | Recipients | Notes |
|---|---|---|---|---|
| quotation.created | Quotation created | `create_quotation` | S (IA) | |
| quotation.sent | Staff shares quote | **New**: today only a client-side `wa.me` link (`QuotationDetailPage`) | C | Needs an explicit "send via WhatsApp" action that emits, replacing wa.me |
| quotation.expiring | `valid_until` within N days | scanner | C, S | N configurable |
| quotation.converted | Status -> converted | quotations UPDATE | C (thanks), S | |
| quotation.lost | Status -> lost | same | S | |
| sale.completed | `create_sale` completes | `create_sale` | C, S, M (IA) | One sale may create several invoices; dedupe per sale |
| invoice.issued | Invoice created | `_milestone_invoice_notify` (exists) | C | Existing |
| invoice.partial | Partial payment recorded | `record_additional_payment` | C | |
| invoice.paid | Fully paid | payment_status -> paid | C, O (IA) | |
| invoice.due_soon | `due_date` within N days | scanner | C | `invoices.due_date` exists |
| invoice.overdue | Past due by N days | scanner | C, O | repeats capped by rule |
| payment.proof_uploaded | UPI proof submitted | `record_payment_proof` | O, M (IA) | |

### 3.3 Service tickets and visits

| Key | Event | Source | Recipients | Notes |
|---|---|---|---|---|
| ticket.created | Booked (any channel) | `service_tickets` INSERT (`_milestone_ticket_notify` exists) | C, O (IA exists) | |
| ticket.assigned | Technician assigned | status -> assigned (exists) | C, T | T today gets in-app `appointment_assigned` only |
| ticket.rescheduled | Slot changed | appointments UPDATE | C, T | New |
| technician.on_the_way | Technician departs | **New** (needs depart action or GPS rule) | C | See gap 1 |
| technician.arrived | Visit started | `service_visits` INSERT (today mis-labelled on_the_way) | C | |
| otp.issued | Visit OTP generated | `generate_visit_otp` | C | In-app banner today; WA = authentication template |
| ticket.completed | Completed | status -> completed (exists) | C, S (if lead-originated), O | |
| ticket.cancelled | Cancelled | `cancel_service_ticket` | C, T | New WA |
| ticket.unassigned_escalated | No technician found / escalated | assignment engine | O, M | IA exists in parts |
| post_service.call_due | N hours after completion: call the customer | scanner | S or O (task) | **New**; creates a task, not a message |
| feedback.requested | Rating request after completion | `runFeedbackRequests` (exists) | C | |
| rating.low | Rating below threshold | rating submit | O, M | New |
| review.google_requested | Completed service, every customer (no rating condition; amended 2026-10-12) | ticket completed + delay | C | See risk 10 |

### 3.4 Warranty, AMC, rentals, referrals

| Key | Event | Source | Recipients |
|---|---|---|---|
| warranty.started | Warranty row created | `warranties` INSERT (via sale) | C |
| warranty.expiring | N days before `expiry_date` (default 30, 7) | scanner | C |
| warranty.expired | Day after expiry | scanner | C |
| amc.joined | Plan sold | `sell_amc_plan`, `sell_amc_plan_onsite`, `create_sale` | C, S |
| amc.visit_scheduled | Visit ticket created for contract | AMC scheduling | C, T |
| amc.visit_reminder | N days before visit (default 1) | scanner | C, T |
| amc.expiring | 30/15/7 before `expiry_date` (windows configurable) | `runAmcReminders` (exists) | C, S |
| amc.expired | Day after expiry | `refresh_amc_statuses` | C, S |
| amc.renewed | Renewal | `renew_amc_plan` | C |
| rental.created / rental.billing_due / rental.returned | Rental lifecycle | `create_rental`, `run_rental_billing`, `mark_rental_returned` | C, O |
| referral.points_awarded | Points credited | `award_referral_points` | C |

### 3.5 Internal / supplier (routed through the same engine, in-app first)

| Key | Event | Today |
|---|---|---|
| po.approval_pending, po.payment_reminder, po.overdue_escalated | PO approval and payment | IA (exists) |
| rfq.monthly_opened, rfq.quote_received, rfq.po_sent | Supplier pipeline | WA to SU (exists, bespoke) |
| stock.low | Technician/warehouse low stock | IA (exists) |
| task.assigned, huddle.reminder | Tasks | IA (exists) |
| tier.promotion_flagged | Technician tiers | IA (exists) |
| wa.send_gave_up | Message abandoned after 3 attempts | IA (exists) |

Phase scope: build 3.1-3.4 first (customer-facing and staff WA). Section 3.5 stays as-is; only the audit/kill-switch layer is shared, and the RFQ supplier path is not migrated in the first release.

## 4. Rule model: what the master configures

One **rule** = one event x one recipient role. An event can have many rules (for example `ticket.assigned` -> customer WA, technician WA, operations IA).

| Setting | Behaviour |
|---|---|
| Event | Picked from the code-owned catalogue (section 3). Master cannot invent events, only configure them. |
| Recipient role | customer / assigned technician / sales person (lead owner) / master / operations / supplier. Resolved at fire time from the subject, never stored as a number. |
| Channel | whatsapp / in_app / both |
| Conditions | Simple, typed filters per event: lead stage, ticket type (paid/warranty/amc/installation/rental), priority, product category (RO/AC/inverter/battery), lead source, amount >= X, rating bounds. No free-form code. |
| Template | One approved template per language; falls back (section 9) |
| Media / link | `video_library` row, document (quote/invoice PDF), or a URL with variables |
| Delay | minutes (0 = immediate), optional "send at HH:MM IST", quiet hours window (default 21:00-08:00 IST, holds until morning) |
| Dedupe | scope + window, see 4.1 |
| Opt-out | respect (default on) |
| Cooldown | minimum days between this rule's sends to the same customer (review request default 90) |
| Max fires | per subject (reminder repeats capped) |
| Status | **test-only** (default for new rules), **live**, **paused** |
| Kill switch | the status toggle on the rule itself, plus the two global switches in 4.3 |
| Version | edits create a new immutable rule version; audit rows reference the version |

### 4.1 Dedupe ("never twice to the same customer")

Literal "never twice per customer per event, ever" would block legitimate repeats (a second ticket, a second AMC). Proposed default and the reason:

- **Idempotency key** (hard unique): `rule_id | customer_id | subject_id | occurrence_key`. `occurrence_key` = the part that distinguishes legit repeats: AMC window (`30`), lead stage code, invoice id, calendar date for daily reminders. The same key can never fire twice, even on replay, retry, or a flipped status.
- **Cooldown** (soft, per rule): no send of the same template to the same customer within N hours/days across all subjects. Stops "ticket completed" and "feedback request" colliding, and a customer with 3 tickets completed in one day getting 3 review requests.
- **Cross-rule suppression**: if two enabled rules resolve to the same template + customer inside the cooldown, the second is audited as `skipped_duplicate`, not sent.

Open question 3 asks whether the stricter "once per customer ever" is wanted for specific events (welcome, review).

### 4.2 Opt-out

- New `customer_comm_prefs`: `wa_opt_out_all`, `wa_opt_out_marketing`, `opted_out_at`, `source` (keyword / staff / app), `language`.
- Inbound STOP / "நிறுத்து" / "unsubscribe" keywords handled in the webhook (a master-editable phrase list, same mechanism as Bot Phrases). One confirmation reply is allowed inside the 24 h window, then silence.
- Template category drives behaviour: **marketing** templates always respect `opt_out_marketing` and `opt_out_all`; **utility** templates respect `opt_out_all` only (a customer who stops promotions still gets "technician on the way"). A rule may set `respect_opt_out = true` to also respect marketing opt-out on utility. Meta requires an opt-out path for marketing; this provides it.

### 4.3 Global kill switches

1. `settings.automation_enabled` (master, instant): engine stops creating queue rows and dispatching; existing queue is held, not discarded.
2. `settings.automation_send_mode`: `live` (default, so deploy changes nothing) | `allowlist_only` | `dry_run` (decisions audited, nothing sent).
3. Existing `whatsapp_bot_enabled` is unchanged and only covers inbound bot replies.

Per-rule status is the third level. All three are visible on the builder page header.

## 5. Schema (sketch, not final SQL)

```
automation_events           -- code-owned catalogue, seeded by migration, read-only to master
  event_key text pk, label_en, label_ta, group, subject_type,
  payload_fields jsonb,       -- the variable names a template may use
  supported_recipients text[], supports_delay boolean, is_scheduled boolean

automation_rules            -- versioned, master-editable
  id, org_id, rule_key (stable id across versions), version int, is_current bool,
  event_key fk, recipient_role, channel,
  conditions jsonb, template_id fk, media jsonb,
  delay_minutes int, send_at_time time, respect_quiet_hours bool,
  dedupe_cooldown_hours int, max_fires int, respect_opt_out bool,
  status text check (status in ('test_only','live','paused')),
  created_by, created_at          -- no UPDATE; edits insert a new version

whatsapp_templates          -- extend existing
  + language text check in ('en','ta'), + meta_template_name text,
  + header_type, + buttons jsonb, + submitted_at, + rejected_reason,
  unique (org_id, name, language)

automation_queue            -- work to do; ephemeral, may be updated
  id, org_id, idempotency_key text UNIQUE, rule_id, rule_version,
  event_key, subject_type, subject_id, customer_id, payload jsonb,
  recipient_role, recipient_ref (profile/customer/supplier id),
  fire_at timestamptz, state text (pending|claimed|done), claimed_at

automation_audit            -- APPEND-ONLY (section 7)

customer_comm_prefs        -- opt-out + language (section 4.2)
customers.is_test boolean not null default false
leads.is_test boolean not null default false   -- leads may have no customer row
settings.automation_enabled, automation_send_mode, automation_quiet_start/end, test_recipient_override
automation_send_allowlist   -- org_id, mobile (10 digits), label, added_by, created_at
```

Existing tables kept: `whatsapp_outbox` stays the transport log (what Wasi was asked and what it said). `automation_audit` is the decision log and links to it by `outbox_id`.

## 6. Engine flow

```
emitter (trigger / RPC hook / scanner)
   -> automation_emit(event_key, subject_type, subject_id, payload)
        1. global automation_enabled? else audit "skipped_global_off"
        2. for each current rule for this event:
             conditions match? else audit "skipped_condition"
             rule status: paused -> audit; test_only and subject not test -> audit "skipped_test_only"
             resolve recipient from subject (role -> person -> number)
             idempotency key insert (ON CONFLICT DO NOTHING) -> conflict => audit "skipped_duplicate"
             queue row with fire_at = now + delay (quiet-hours adjusted)
dispatcher (Edge Function, existing 5-min GH cron + wa-dispatch-now for delay=0)
   claim due rows (FOR UPDATE SKIP LOCKED), then per row, in this order:
        a. global kill / dry_run
        b. rule still live? (re-check: master may have paused after queueing)
        c. send_mode allowlist + test override (section 10)
        d. opt-out
        e. cooldown / cross-rule suppression
        f. template resolution: customer language -> en fallback; approved? else audit "skipped_no_approved_template"
        g. 24 h window: inside -> free text allowed only if rule opts in; outside -> template required
        h. sendMessage()  -> outbox row + raw provider response
        i. audit result row (sent / failed / provider_rejected, raw error)
```

Emitters are deliberately thin. **Triggers only call `automation_emit`**; they never insert into `whatsapp_outbox` or resolve templates (that is exactly the pattern that produced defects 2 and 3). Scanners (warranty/AMC/invoice/quotation/post-service) take a `p_now` parameter, the same convention as `run_lead_followup_notifications(p_now)`, so tests can simulate time.

Scheduling: pg_cron is already enabled and used (lead follow-ups) so scanners can be pure SQL on pg_cron. Dispatch needs HTTP (no `pg_net`), so it stays on the existing GH Actions cron plus on-demand `wa-dispatch-now`. GH cron is best-effort; 5-15 min drift is normal, so "delay" has a practical floor of about 5 minutes and a ceiling of drift. State this to the master in the UI.

## 7. Audit design (append-only)

`automation_audit`, one row per **decision**, never updated. A send is two rows (`queued`, then `sent`/`failed`), not one row mutated.

| Column | Meaning |
|---|---|
| id, org_id, occurred_at | |
| run_id | groups all rows of one emit-to-outcome chain |
| event_key, subject_type, subject_id | what happened |
| rule_id, rule_version, rule_key | which rule (immutable version) |
| recipient_role | customer / technician / sales / master / operations / supplier |
| recipient_customer_id / recipient_profile_id | who it was meant for |
| recipient_masked | last 4 digits only, e.g. `******6740` |
| actual_destination_masked | differs from the above only under test override |
| channel, template_name, template_language, template_id | |
| decision | `queued`, `sent`, `failed`, `provider_rejected`, `skipped_global_off`, `skipped_condition`, `skipped_test_only`, `skipped_duplicate`, `skipped_cooldown`, `skipped_opt_out`, `skipped_no_approved_template`, `skipped_quiet_hours_held`, `blocked_not_allowlisted`, `dry_run` |
| status, error | provider status and raw error text (e.g. the 409 body) |
| outbox_id, wa_message_id | link to the transport row |
| is_test | copied from subject |
| idempotency_key | |
| actor | `system` or the profile that fired/changed it |

Enforcement:
- RLS: select for master/ops; **no INSERT/UPDATE/DELETE policy** for any app role.
- A `BEFORE UPDATE OR DELETE` trigger raises an exception unconditionally, so even `service_role` cannot rewrite history (RLS does not stop service_role; the trigger does).
- Inserts only via `SECURITY DEFINER` functions, with `REVOKE EXECUTE ... FROM anon, authenticated` per the default-privileges leak noted 2026-08-27.
- Retention: rows are small; keep indefinitely, partition by month if volume demands.
- Rule edits and global switch changes also write audit rows (`decision='config_changed'`, with before/after), in addition to the existing `audit_master_change` trigger.

## 8. Flow builder (master UI)

New tab **Automation > Triggers** (existing Flows tab is superseded; its rows migrate).

1. **Event list** grouped as in section 3, each showing live/test-only/paused rule counts and last fired.
2. **Rule editor**: event -> recipient -> conditions (typed pickers) -> template + language preview with a live variable table -> media/link -> delay + quiet hours -> dedupe/cooldown -> opt-out -> status.
3. **Simulate** button: choose a real sample subject (test customer by default) and see exactly which rules would fire and what each gate would decide, with the rendered message. No send.
4. **Audit view**: filter by event, rule, recipient role, decision, customer, date; export CSV.
5. **Global bar**: automation on/off, send mode, allow-list editor, count of rules in test-only.
6. Everything master-editable; nothing hard-coded. Bodies, windows (30/15/7), cooldowns, quiet hours all live in rules/settings. EN + TA labels follow the existing i18n convention.

## 9. WhatsApp constraints and the template submission list

### 9.1 Constraints that shape the design

- **Outside the 24 h window only approved templates can be sent.** The codebase has never sent a template; all sends are free text (verified 2026-09-03). Business-initiated events (reminders, invoices, review requests) almost always fall outside the window. Without templates these sends are likely being rejected. This is probably the dominant failure mode and may be the 409.
- **Wasi's template payload is unconfirmed.** The existing `templateSend` shape (`template`, `headerMediaUrl`, `params`) is this codebase's guess. We need Wasi's real sample payload for: template with body variables, template with URL button variable, template with video/document header.
- **Wasi 409.** Undiagnosed. Engine handling: record the raw body in `automation_audit.error`, classify as `provider_rejected`, retry at most per existing cap (3), and surface in Failed Sends. Diagnosis (later, test number only, with approval): send one approved template to the test number and one free-text outside the window, capture both raw responses.
- **No template submission API.** Submission is dashboard-only via Wasi (2026-09-03 finding). 64 submissions is a real chore, so phased waves below.
- **Meta template rules to respect**: lowercase letters/digits/underscores; body max 1024 chars; variables `{{1}}..{{n}}` sequential, body must not start or end with a variable, no two adjacent variables; each variable needs a sample value on submission; one name can exist in several languages; categories are `utility`, `marketing`, `authentication` and Meta may recategorise a utility template to marketing (pricier, opt-out required).
- **Videos**: use a link in the body (YouTube/Drive URL as a variable) for launch. A video-header template needs a media handle and the unconfirmed payload shape.
- **Language**: Meta codes `en` and `ta`. The engine picks `profiles.language` of the customer's login; customers without a login use the rule's default language.

### 9.2 Templates to submit

Prefix `gvm_` keeps names unique. Each name is submitted twice, `en` and `ta` (variable order identical). Variables in square brackets. Wave 1 is the minimum to make the current live behaviour compliant plus the review message.

| # | Name | Category | Events | Variables | Wave |
|---|---|---|---|---|---|
| 1 | gvm_service_booked | utility | ticket.created | name, ticket_ref, complaint | 1 |
| 2 | gvm_technician_assigned | utility | ticket.assigned | name, ticket_ref, technician, slot | 1 |
| 3 | gvm_technician_on_the_way | utility | technician.on_the_way | name, technician, ticket_ref, eta | 1 |
| 4 | gvm_technician_arrived | utility | technician.arrived | name, technician, ticket_ref | 2 |
| 5 | gvm_service_completed | utility | ticket.completed | name, ticket_ref, summary_link | 1 |
| 6 | gvm_service_cancelled | utility | ticket.cancelled | name, ticket_ref | 2 |
| 7 | gvm_service_rescheduled | utility | ticket.rescheduled | name, ticket_ref, new_slot | 2 |
| 8 | gvm_feedback_request | utility | feedback.requested | name, ticket_ref, rating_link | 1 |
| 9 | gvm_google_review | marketing | review.google_requested | name, service, review_url | 1 |
| 10 | gvm_enquiry_received | utility | product_enquiry.submitted, spare_enquiry.submitted, callback.requested | name, item, enquiry_ref | 2 |
| 11 | gvm_lead_welcome | utility | lead.created | name, sales_person, sales_phone, interest | 2 |
| 12 | gvm_enquiry_video | marketing | enquiry.keyword_flow | name, topic, video_url | 2 |
| 13 | gvm_quotation_sent | utility | quotation.sent | name, quote_ref, total, valid_until, link | 2 |
| 14 | gvm_quotation_expiring | marketing | quotation.expiring | name, quote_ref, valid_until | 3 |
| 15 | gvm_invoice_issued | utility | sale.completed, invoice.issued | name, invoice_no, amount, link | 1 |
| 16 | gvm_payment_received | utility | invoice.paid, invoice.partial | name, amount, invoice_no | 2 |
| 17 | gvm_payment_due | utility | invoice.due_soon | name, amount, invoice_no, due_date | 2 |
| 18 | gvm_payment_overdue | utility | invoice.overdue | name, amount, invoice_no, days_overdue | 3 |
| 19 | gvm_warranty_started | utility | warranty.started | name, product, expiry_date | 2 |
| 20 | gvm_warranty_expiring | utility | warranty.expiring | name, product, expiry_date, days | 2 |
| 21 | gvm_amc_welcome | utility | amc.joined | name, plan, product, expiry_date | 1 |
| 22 | gvm_amc_visit_scheduled | utility | amc.visit_scheduled | name, product, visit_date | 1 |
| 23 | gvm_amc_visit_reminder | utility | amc.visit_reminder | name, product, visit_date | 1 |
| 24 | gvm_amc_expiring | utility | amc.expiring (30/15/7) | name, product, expiry_date, days | 1 |
| 25 | gvm_amc_expired | utility | amc.expired | name, product, expiry_date | 2 |
| 26 | gvm_amc_renewed | utility | amc.renewed | name, product, new_expiry | 2 |
| 27 | gvm_rental_billing | utility | rental.billing_due | name, amount, period | 3 |
| 28 | gvm_referral_points | marketing | referral.points_awarded | name, points, balance | 3 |
| 29 | gvm_staff_job_assigned | utility | ticket.assigned (T) | technician, ticket_ref, area, slot | 2 |
| 30 | gvm_staff_new_lead | utility | lead.created / lead.assigned (S) | sales_person, lead_name, interest, source | 2 |
| 31 | gvm_staff_alert | utility | rating.low, escalations (M/O) | alert_title, details | 2 |
| 32 | gvm_visit_otp | authentication | otp.issued | code (Meta-fixed body, optional) | 3 |

Count: 32 names x 2 languages = 64 submissions (Wave 1 = 10 names, 20 submissions).

### 9.3 Message bodies (EN, TA)

Tamil is a **draft for native review** (same convention as `docs/tamil-review*.md`); do not submit before review. No body starts or ends with a variable.

1. **gvm_service_booked**
   EN: Hi {{1}}, your service request {{2}} for {{3}} is booked with GV Mart. We will assign a technician shortly and keep you updated.
   TA: வணக்கம் {{1}}, உங்கள் சேவை கோரிக்கை {{2}} ({{3}}) GV Mart-இல் பதிவு செய்யப்பட்டது. விரைவில் தொழில்நுட்ப வல்லுநரை நியமித்து தகவல் தெரிவிப்போம்.
2. **gvm_technician_assigned**
   EN: Hi {{1}}, for your service request {{2}}, technician {{3}} has been assigned. Scheduled time: {{4}}. You can track the visit in the GV Mart app.
   TA: வணக்கம் {{1}}, உங்கள் சேவை கோரிக்கை {{2}}-க்கு தொழில்நுட்ப வல்லுநர் {{3}} நியமிக்கப்பட்டுள்ளார். நேரம்: {{4}}. GV Mart செயலியில் வருகையைக் கண்காணிக்கலாம்.
3. **gvm_technician_on_the_way**
   EN: Hi {{1}}, {{2}} is on the way for your request {{3}} and should reach you in about {{4}}.
   TA: வணக்கம் {{1}}, உங்கள் கோரிக்கை {{3}}-க்காக {{2}} புறப்பட்டுள்ளார். சுமார் {{4}} நேரத்தில் வந்து சேர்வார்.
   (Variable order note: Meta accepts sequential numbering; if it rejects out-of-order appearance in TA, swap to name, ticket_ref, technician, eta in both languages.)
4. **gvm_technician_arrived**
   EN: Hi {{1}}, technician {{2}} has arrived for your request {{3}} and started the service.
   TA: வணக்கம் {{1}}, தொழில்நுட்ப வல்லுநர் {{2}} உங்கள் கோரிக்கை {{3}}-க்காக வந்து சேவையைத் தொடங்கியுள்ளார்.
5. **gvm_service_completed**
   EN: Hi {{1}}, your service request {{2}} is completed. Details: {{3}} . Thank you for choosing GV Mart.
   TA: வணக்கம் {{1}}, உங்கள் சேவை கோரிக்கை {{2}} முடிவடைந்தது. விவரங்கள்: {{3}} . GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி.
6. **gvm_service_cancelled**
   EN: Hi {{1}}, your service request {{2}} has been cancelled. Call us if you would like to book again.
   TA: வணக்கம் {{1}}, உங்கள் சேவை கோரிக்கை {{2}} ரத்து செய்யப்பட்டது. மீண்டும் பதிவு செய்ய எங்களை அழைக்கவும்.
7. **gvm_service_rescheduled**
   EN: Hi {{1}}, your service request {{2}} has been rescheduled to {{3}}. Sorry for the change.
   TA: வணக்கம் {{1}}, உங்கள் சேவை கோரிக்கை {{2}} {{3}}-க்கு மாற்றப்பட்டுள்ளது. சிரமத்திற்கு வருந்துகிறோம்.
8. **gvm_feedback_request**
   EN: Hi {{1}}, how was your recent service {{2}}? Please rate us in one tap: {{3}} . Your feedback helps us improve.
   TA: வணக்கம் {{1}}, உங்கள் சமீபத்திய சேவை {{2}} எப்படி இருந்தது? ஒரே தட்டலில் மதிப்பிடுங்கள்: {{3}} . உங்கள் கருத்து எங்களை மேம்படுத்தும்.
9. **gvm_google_review** (the Google review message)
   EN: Hi {{1}}, thank you for choosing GV Mart for {{2}}. If you have a minute, we would be grateful for a Google review: {{3}} . Thank you for your support!
   TA: வணக்கம் {{1}}, {{2}}-க்காக GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி. ஒரு நிமிடம் ஒதுக்கி Google-இல் மதிப்பாய்வு எழுதினால் மகிழ்வோம்: {{3}} . உங்கள் ஆதரவிற்கு நன்றி!
   Notes: `{{3}}` = `settings.google_review_url`. Amended 2026-10-12: submitted as Utility with no staff name, no incentive and no rating condition (see the Wave 1 sheet); cooldown 90 days; **do not restrict to high ratings**.
10. **gvm_enquiry_received**
    EN: Hi {{1}}, we received your enquiry for {{2}} (ref {{3}}). Our team will contact you shortly.
    TA: வணக்கம் {{1}}, {{2}} குறித்த உங்கள் விசாரணை (குறிப்பு {{3}}) எங்களுக்கு கிடைத்தது. எங்கள் குழு விரைவில் தொடர்பு கொள்ளும்.
11. **gvm_lead_welcome**
    EN: Hi {{1}}, thanks for your interest in {{4}}. I am {{2}} from GV Mart and will help you. You can reach me on {{3}} .
    TA: வணக்கம் {{1}}, {{4}} மீதான உங்கள் ஆர்வத்திற்கு நன்றி. நான் GV Mart-இலிருந்து {{2}}. என்னை {{3}} என்ற எண்ணில் தொடர்பு கொள்ளலாம்.
    (Same order caveat as #3: reorder the variable list to name, sales_person, sales_phone, interest if appearance order is enforced.)
12. **gvm_enquiry_video**
    EN: Hi {{1}}, here is a short video about {{2}} that answers common questions: {{3}} . Reply here if you would like a quotation.
    TA: வணக்கம் {{1}}, {{2}} பற்றிய பொதுவான கேள்விகளுக்கு பதிலளிக்கும் சிறு வீடியோ: {{3}} . விலைப்பட்டியல் வேண்டுமெனில் இங்கே பதிலளிக்கவும்.
13. **gvm_quotation_sent**
    EN: Hi {{1}}, your quotation {{2}} for Rs {{3}} is ready and valid until {{4}}. View it here: {{5}} .
    TA: வணக்கம் {{1}}, உங்கள் விலைப்பட்டியல் {{2}} (ரூ {{3}}) தயாராக உள்ளது, {{4}} வரை செல்லுபடியாகும். இங்கே பார்க்கலாம்: {{5}} .
14. **gvm_quotation_expiring**
    EN: Hi {{1}}, your quotation {{2}} expires on {{3}}. Reply here if you would like to go ahead or need changes.
    TA: வணக்கம் {{1}}, உங்கள் விலைப்பட்டியல் {{2}} {{3}} அன்று காலாவதியாகிறது. தொடர விரும்பினால் அல்லது மாற்றங்கள் தேவைப்பட்டால் பதிலளிக்கவும்.
15. **gvm_invoice_issued**
    EN: Hi {{1}}, your invoice {{2}} for Rs {{3}} is ready. View it here: {{4}} . Thank you for shopping with GV Mart.
    TA: வணக்கம் {{1}}, உங்கள் விலைப்பட்டியல்/இன்வாய்ஸ் {{2}} (ரூ {{3}}) தயாராக உள்ளது. இங்கே பார்க்கலாம்: {{4}} . GV Mart-இல் வாங்கியதற்கு நன்றி.
16. **gvm_payment_received**
    EN: Hi {{1}}, we received your payment of Rs {{2}} against invoice {{3}}. Thank you.
    TA: வணக்கம் {{1}}, இன்வாய்ஸ் {{3}}-க்கான ரூ {{2}} பணம் பெற்றுக்கொண்டோம். நன்றி.
17. **gvm_payment_due**
    EN: Hi {{1}}, a payment of Rs {{2}} for invoice {{3}} is due on {{4}}. Please pay at your convenience. Thank you.
    TA: வணக்கம் {{1}}, இன்வாய்ஸ் {{3}}-க்கான ரூ {{2}} {{4}} அன்று செலுத்த வேண்டியது. வசதிக்கேற்ப செலுத்தவும். நன்றி.
18. **gvm_payment_overdue**
    EN: Hi {{1}}, Rs {{2}} for invoice {{3}} is overdue by {{4}} days. Please pay soon or call us if you have already paid.
    TA: வணக்கம் {{1}}, இன்வாய்ஸ் {{3}}-க்கான ரூ {{2}} {{4}} நாட்கள் தாமதமாகிறது. விரைவில் செலுத்தவும்; ஏற்கனவே செலுத்தியிருந்தால் எங்களை அழைக்கவும்.
19. **gvm_warranty_started**
    EN: Hi {{1}}, the warranty on your {{2}} is active until {{3}}. Keep your invoice handy for any claim.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான உத்தரவாதம் {{3}} வரை செயலில் உள்ளது. கோரிக்கைக்கு இன்வாய்ஸை வைத்திருக்கவும்.
20. **gvm_warranty_expiring**
    EN: Hi {{1}}, the warranty on your {{2}} ends on {{3}} ({{4}} days left). Ask us about an AMC plan to stay covered.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான உத்தரவாதம் {{3}} அன்று முடிகிறது ({{4}} நாட்கள் உள்ளன). தொடர்ந்து பாதுகாப்பு பெற AMC திட்டம் பற்றி கேளுங்கள்.
21. **gvm_amc_welcome**
    EN: Hi {{1}}, welcome to the {{2}} AMC for your {{3}}. Your plan is valid until {{4}}. We will remind you before each visit.
    TA: வணக்கம் {{1}}, உங்கள் {{3}}-க்கான {{2}} AMC திட்டத்திற்கு வரவேற்கிறோம். திட்டம் {{4}} வரை செல்லுபடியாகும். ஒவ்வொரு வருகைக்கும் முன் நினைவூட்டுவோம்.
22. **gvm_amc_visit_scheduled**
    EN: Hi {{1}}, your AMC service visit for {{2}} is scheduled on {{3}}. We will remind you before the visit.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான AMC சேவை வருகை {{3}} அன்று திட்டமிடப்பட்டுள்ளது. வருகைக்கு முன் நினைவூட்டுவோம்.
23. **gvm_amc_visit_reminder**
    EN: Hi {{1}}, a reminder that your AMC service visit for {{2}} is on {{3}}. Please keep the unit accessible.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான AMC சேவை வருகை {{3}} அன்று உள்ளது என்பதை நினைவூட்டுகிறோம். சாதனத்தை அணுக வசதி செய்யவும்.
24. **gvm_amc_expiring**
    EN: Hi {{1}}, your AMC for {{2}} expires on {{3}} (in {{4}} days). Reply here to renew or talk to our team.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான AMC {{3}} அன்று முடிவடைகிறது ({{4}} நாட்களில்). புதுப்பிக்க இங்கே பதிலளிக்கவும் அல்லது எங்கள் குழுவுடன் பேசவும்.
25. **gvm_amc_expired**
    EN: Hi {{1}}, your AMC for {{2}} expired on {{3}}. Reply here to renew and keep your service coverage.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான AMC {{3}} அன்று முடிவடைந்தது. சேவை பாதுகாப்பைத் தொடர புதுப்பிக்க இங்கே பதிலளிக்கவும்.
26. **gvm_amc_renewed**
    EN: Hi {{1}}, your AMC for {{2}} has been renewed and is valid until {{3}}. Thank you for staying with GV Mart.
    TA: வணக்கம் {{1}}, உங்கள் {{2}}-க்கான AMC புதுப்பிக்கப்பட்டது, {{3}} வரை செல்லுபடியாகும். GV Mart-உடன் இருப்பதற்கு நன்றி.
27. **gvm_rental_billing**
    EN: Hi {{1}}, your rental bill of Rs {{2}} for {{3}} is ready. Please contact us for payment options.
    TA: வணக்கம் {{1}}, {{3}} காலத்திற்கான உங்கள் வாடகை பில் ரூ {{2}} தயாராக உள்ளது. பணம் செலுத்தும் வழிகளுக்கு எங்களை தொடர்பு கொள்ளவும்.
28. **gvm_referral_points**
    EN: Hi {{1}}, you earned {{2}} referral points. Your balance is now {{3}} points. Thank you for recommending GV Mart.
    TA: வணக்கம் {{1}}, நீங்கள் {{2}} பரிந்துரை புள்ளிகள் பெற்றீர்கள். இப்போதைய இருப்பு {{3}} புள்ளிகள். GV Mart-ஐ பரிந்துரைத்ததற்கு நன்றி.
29. **gvm_staff_job_assigned** (technician)
    EN: Hi {{1}}, new job {{2}} assigned to you in {{3}} at {{4}}. Open the GV Mart app for details.
    TA: வணக்கம் {{1}}, உங்களுக்கு புதிய வேலை {{2}} {{3}} பகுதியில் {{4}} நேரத்தில் ஒதுக்கப்பட்டுள்ளது. விவரங்களுக்கு GV Mart செயலியைத் திறக்கவும்.
30. **gvm_staff_new_lead** (sales person)
    EN: Hi {{1}}, a new lead {{2}} for {{3}} came in from {{4}} . Please call within the target time.
    TA: வணக்கம் {{1}}, {{4}} மூலம் {{3}} குறித்த புதிய லீட் {{2}} வந்துள்ளது. இலக்கு நேரத்திற்குள் அழைக்கவும்.
31. **gvm_staff_alert** (master / operations)
    EN: GV Mart alert: {{1}} . Details: {{2}} . Please review in the app.
    TA: GV Mart எச்சரிக்கை: {{1}} . விவரம்: {{2}} . செயலியில் பார்க்கவும்.
32. **gvm_visit_otp**: authentication category; Meta supplies the fixed body ("{{1}} is your verification code") with a copy-code button; only the code is passed. Optional and only if in-app OTP delivery is not enough.

Design note on the review message: `{{3}}` as a full URL in the body avoids a dynamic-URL button (Meta requires a fixed base plus one variable suffix; Google short links are awkward to split). Revisit once Wasi's button payload is confirmed.

## 10. Test-customer flag, report exclusion, and test-send allow-list

### 10.1 Test-customer flag

- `customers.is_test` and `leads.is_test` (leads can exist without a customer row). All other records inherit through `customer_id`; a helper `public.is_test_customer(customer_id)` keeps filters one-liners.
- Every aggregate must exclude test data. Surfaces that need the filter (to be audited exhaustively at build time with a grep for every `from customers|service_tickets|invoices|sales|leads|amc_contracts|...` in `report_*`, dashboard hooks, incentives, KPIs, counts):
  - the SQL report functions (`report_*`, on `fix/reports-sql-aggregation`) and all dashboard tiles (Owner, Sales, Service, Accounts);
  - technician KPIs: jobs, ratings, reviews, incentives (a test ticket must never earn a real technician incentive or a rating);
  - sales: revenue, collected/invoiced, round-robin counters, lead counts and conversion;
  - AMC/warranty counts, referral points, gift stock, inventory decrements;
  - the lead digest and notifications (test lead events must not spam real staff);
  - badge counts in the nav.
- A guard test: a SQL check that lists every `report_*`/KPI function not referencing `is_test`, so a future report cannot silently include test data. Fails CI.
- UI: a visible "TEST" chip on test customer/ticket/lead rows; a master toggle "show test data" (default off) in list pages.
- Safety constraint on the flag: `is_test` can only be set by master, and changing it writes an audit row; a trigger refuses to flip it on a customer that has real (non-test-linked) invoices without explicit confirmation.

### 10.2 Test-send allow-list

- Table `automation_send_allowlist` (10-digit numbers + label). Initially exactly one row: the test number.
- Enforcement lives **inside `sendMessage()`** (the single seam), so it covers the new engine, the bot, `wa-scheduled-tasks`, `wa-milestone-dispatch-core`, and supplier RFQ.
- Behaviour by `settings.automation_send_mode`:
  - `live`: allow-list ignored (production default; deploying changes nothing).
  - `allowlist_only`: a send to a number not on the list is **blocked, not sent**, an audit row `blocked_not_allowlisted` is written (masked number, template, rule, caller), and `sendMessage` returns a non-dispatched result so callers do not retry forever (the block is terminal, `retried_at` stamped).
  - `dry_run`: nothing leaves, every decision is audited.
- **Rule status `test_only`** is the per-rule layer: such a rule fires only when the subject `is_test`. New rules default to it, so a master cannot accidentally message real customers while building. Promotion to `live` is an explicit action with an audit row.
- **Test recipient override** (`settings.test_recipient_override`): for test subjects, staff roles (technician, sales, master, operations) are resolved normally for audit (so we prove the engine picked the right person) but the physical destination is replaced with the test number. Audit stores `recipient_masked` (intended) and `actual_destination_masked` (override). This is what lets the end-to-end plan prove recipient routing without messaging any real staff member.
- Hard stop in the dispatcher: in any mode, if the subject is `is_test` and the destination is not on the allow-list, block. Test data can never reach a real number even if the override is misconfigured.

### 10.3 Test fixtures required (all live writes, proposal only, see section 15)

1. Test customer "jeshee test trigger" (Sirah Digital, Pallavaram), `is_test = true`.
2. A **test technician** and a **test sales person**. Otherwise the assignment engine and the round-robin will assign test tickets/leads to a real technician or sales person, put the job on their schedule, send them in-app notifications and distort their KPIs. This conflicts with the standing rule's spirit (only the test customer may be touched). Memory notes a `TECHNICIAN_TEST_*` login exists in `.env.test`: if that account is a dedicated test technician it can be reused; I cannot tell from code whether it is a real person.
3. Check that the test number is not also registered as a supplier (2026-08-26 collision: the supplier check silently wins and the bot never replies as customer).

## 11. End-to-end test plan (written, not run)

### 11.1 Preconditions

- Fixtures from 10.3 exist and are approved; `automation_send_mode = allowlist_only`; allow-list contains only the test number; `test_recipient_override` = test number; all rules `test_only`.
- Wave-1 templates approved in Meta for the language under test (else the correct expected result is `skipped_no_approved_template`, which is itself a passing assertion).
- Wasi 409 diagnosed or explicitly accepted (a send that returns 409 is a recorded `provider_rejected`, not a harness failure).
- No supplier-flow rule included; RFQ paths are out of scope.

### 11.2 Method per event

Each event is a row in a table-driven test: **fire** (how), **expect** (audit rows, recipients, template, status), **negative checks**.

1. Fire through the real entry point as the test customer (RPC or scanner with `p_now`): never by inserting audit rows directly.
2. Poll `automation_audit` by `run_id` until a terminal decision; assert exact set of rows, not just "something was sent".
3. For every rule on the event assert: `recipient_role`, intended recipient is the right person (test technician/sales for T/S), `actual_destination_masked` is the test number, `template_name` + `template_language` match the rule and the customer's language, variables resolved (no empty/`{{n}}` left in the rendered body), `status` and `outbox_id` link.
4. Physical confirmation: the user checks the single test handset for the count and wording of messages; the harness prints the expected list beforehand ("expect 3 messages: ...").

### 11.3 Event-by-event firing table

| Event(s) | How to fire (test customer only) | Expected audit rows |
|---|---|---|
| lead.created, lead.assigned | New Lead via form with test mobile; then WhatsApp enquiry from the test number | S rule (staff template via override), C ack, M IA; owner = test sales person |
| lead.stage.* | Log outcomes moving the test lead: contacted, quoted, won; separate test lead to lost; reopen | one row group per stage; C rules fire only where enabled; lost -> no C message |
| lead.followup.due/overdue/stuck | Set follow-up, run `run_lead_followup_notifications(p_now)` at simulated times; postpone repeatedly | S (+M) rows; no duplicate on a second run (dedupe) |
| callback.requested, product/spare enquiry | App enquiry + callback as test customer; WA spare enquiry from test number | C ack, S/O rows |
| enquiry.keyword_flow | Send a topic keyword from the test number | C video/link row; template or in-window free text per rule |
| quotation.created/sent/expiring/converted/lost | Create quote, press send, scanner with `p_now` past `valid_until - N`, convert, a second quote to lost | C quote template with link; expiring only once |
| sale.completed, invoice.issued/partial/paid/due_soon/overdue | Create a test sale (service-only line, no stock impact), record partial then full payment, scanner with simulated dates | each template once; paid after partial is a separate occurrence key |
| payment.proof_uploaded | Upload UPI proof on a test invoice | O row |
| ticket.created/assigned/rescheduled/cancelled | Book via app, auto-assign (to test technician), reschedule, cancel a second ticket | C and T rows; T via override |
| technician.on_the_way, arrived, otp.issued | Technician app depart action (when built), start visit, OTP | one row each; on_the_way is not emitted by visit start |
| ticket.completed, feedback.requested, review.google_requested, rating.low, post_service.call_due | Complete via OTP, submit ratings 5 and 2 | completed C; feedback after delay; review per rule; low rating -> M/O alert; call task created |
| warranty.started/expiring/expired | Sale with warranty; scanner at simulated dates (30, 7, +1) | one per window |
| amc.joined/visit_scheduled/visit_reminder/expiring/expired/renewed | Sell plan to test customer; scanner at T-30/15/7; renew; expire | exactly one row per window; renew suppresses further expiring |
| rental.*, referral.points_awarded | Test rental create/bill/return; award points | C rows |

### 11.4 Cross-cutting negative tests

| Test | Pass condition |
|---|---|
| Re-fire the same event/subject | `skipped_duplicate`, no second send |
| Two rules, same template, same customer | second `skipped_cooldown` |
| Opt out via STOP keyword, then fire utility + marketing | marketing `skipped_opt_out`; utility per policy; confirmation reply sent once |
| Send to a number not on the allow-list (call `sendMessage` via a throwaway rule with a non-test subject in `allowlist_only`) | `blocked_not_allowlisted`, nothing sent, no retry |
| Global kill on mid-queue | queued rows held, no sends, audit `skipped_global_off`; turn back on, they drain |
| Rule paused after queueing | dispatcher re-check -> skipped |
| No approved template / language missing | `skipped_no_approved_template` (and falls back to `en` only if rule allows) |
| Outside 24 h window, no template | not free-texted |
| Quiet hours | held to 08:00 IST, then sent |
| Provider returns 409 | `provider_rejected`, raw body in `error`, max 3 attempts, one `wa.send_gave_up` IA |
| Audit immutability | attempted UPDATE/DELETE as service_role raises |
| Test data isolation | after the run, every report/KPI/count shows zero test effect (compare before/after snapshots of dashboard and report outputs) |
| Replay (re-run webhook delivery twice) | idempotent |

### 11.5 Exit criteria

100% of rows in 11.3 observed with expected audit sets; all 11.4 pass; zero messages to any number except the test number (verified by querying audit and outbox for non-test destinations); before/after KPI snapshot identical. Results written to `docs/automation-test-results.md` with masked numbers only.

## 12. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Templates not approved / Wasi payload for templates unconfirmed: most business-initiated events cannot send | Phase 0 first; engine audits `skipped_no_approved_template` rather than free-texting; get Wasi's real template payload before building the sender |
| 2 | The 409 is a symptom of the 24 h rule and everything currently "sent" outside the window is silently failing | Diagnose with one send to the test number in a later approved step; audit raw responses |
| 3 | Behaviour change at cutover (messages start or stop) | Shadow mode: engine runs in `dry_run` beside the old triggers, compare, then switch per event; old paths removed only after parity |
| 4 | Double sending during migration (old trigger + new engine) | Per-event cutover flag; old trigger checks it; idempotency key includes event/subject |
| 5 | Test data leaking into KPIs/incentives/inventory | 10.1 filter audit + CI guard; test sale uses non-stock line items |
| 6 | Real staff pinged by test events | Test technician/sales + recipient override |
| 7 | Spam/complaints: quality rating drop, number blocked by Meta | Cooldowns, opt-out, quiet hours, marketing separated, rule-count visible, a global per-customer daily cap (default 3 WA/day) |
| 8 | Utility template reclassified to marketing by Meta (cost, opt-out) | Submit honestly; engine reads category per template, not per event |
| 9 | Cron drift (GitHub Actions): delays and scanners late | State floor in UI; scanners are idempotent and use a catch-up window; pg_cron for SQL scanners |
| 10 | **Google review policy** (April 2026 update): no review gating, no quotas or targets, no staff names or content-specific requests, no payment or discounts, no pressure on the premises; the existing 4.5+ star in-app rule has the same exposure | Request from all completed services; no technician incentive or target tied to reviews; QR offered not pushed; reviews recorded for reporting only; route <4 stars to an internal alert in addition, not instead |
| 11 | Parallel branches (lead stack, reports) merge-conflict with hooks and report filters | Build on merged stack; keep emit hooks as one-line `perform automation_emit(...)` additions |
| 12 | Free-form rules become a foot-gun (loop: event emits another event) | Events catalogue is code-owned; rules cannot emit; per-subject max fires; per-customer daily cap |
| 13 | `automation_audit` volume | Small rows, indexed by (org, occurred_at), (run_id), (customer); monthly partitioning if needed |
| 14 | Tamil translations sent without review | Block submission until reviewed; template rows carry `reviewed_by` |
| 15 | PII in audit | Masked numbers only; payload not stored, only variable names and the rendered body hash (rendered body stays in the outbox) |

## 13. Phasing and effort

Estimates are for one developer, include live verification, exclude time waiting on Meta/Wasi. Treat as ranges, not commitments.

| Phase | Scope | Effort |
|---|---|---|
| 0. Unblock | Wasi sample payloads (template body vars, URL button, document/video header); diagnose 409 with one approved test send; submit Wave-1 templates (20 submissions); native Tamil review; decisions in section 14 | 1-2 days of mine + external wait (unbounded) |
| 1. Foundation | Schema, `automation_emit`, queue, dispatcher gates, `sendMessage` allow-list/kill/dry-run, append-only audit, opt-out table + STOP handling, template columns | 4-5 days |
| 2. Customer-facing emitters | Hooks for service/AMC/invoice/lead stages; existing triggers re-pointed; old paths behind cutover flag; shadow mode | 4-6 days |
| 3. Scanners | Warranty, AMC, invoice, quotation, post-service call, followup with `p_now` | 2-3 days |
| 4. Builder UI | Triggers tab, rule editor, simulate, audit view, global bar, en/ta strings | 5-6 days |
| 5. Test fixtures + harness | Test customer/technician/sales, `is_test` filters everywhere, CI guard, table-driven e2e runner, results doc | 4-5 days |
| 6. Cutover | Per-event switch from shadow to live, retire hard-coded constants and old triggers | 2-3 days spread over a week of observation |

Total build: roughly 3-4 weeks of focused work. The risky part is Phase 0 and the exhaustive report filter audit in Phase 5, not the engine.

Suggested first release (smallest valuable slice): service lifecycle (booked/assigned/on the way/completed), feedback + Google review, invoice issued, AMC welcome/visit/expiring. That is Wave-1 templates only.

## 14. Open questions (need your answers)

1. **Is production currently messaging real customers?** If yes, default `send_mode = live` and shadow mode matter; if the bot is effectively off, cutover is simpler.
2. **Real "on the way".** Add a "Start travel" action to the technician app (new tap, accurate), or derive from first GPS ping after assignment/slot start (no extra tap, noisier)? Today there is no departure signal.
3. **Dedupe strictness.** Per (subject, rule) plus a cooldown (my default), or "once per customer ever" for specific events (welcome, review)? And what review cooldown (default 90 days)?
4. **Opt-out scope.** Is "STOP" all WhatsApp or promotions only? Do transactional messages (technician on the way, invoice) continue after STOP?
5. **Review requests.** Answered 2026-10-12: ask every completed-service customer, no rating condition, no technician incentive, target or quota, no staff name. Which services qualify is still open (default: all).
6. **Which events should message customers by default** (vs staff only)? e.g. lead stage "contacted"/"quoted" to the customer is unusual; I suggest only won -> thank-you. Lost never.
7. **Staff WhatsApp.** Do technicians, sales people and master want WhatsApp for these events or stay in-app only? WA to staff costs templates 29-31 and a number for each.
8. **Quote/invoice sharing.** Replace the client-side `wa.me` share buttons with a server-side send (needed for audit and templates)? Staff lose "edit text before sending".
9. **Languages.** customers without a login have no language field: add `customers.preferred_language`, or follow the sales person's choice at capture?
10. **Test fixtures.** Reuse the `TECHNICIAN_TEST_*` account as the test technician (is it a real person?), and create a dedicated test sales person? Is an extra `is_test` staff profile acceptable under your standing rule?
11. **Test sales affecting stock/finance.** OK to use a service-only invoice line so no inventory moves? Invoice numbers still consume sequence; acceptable?
12. **Quiet hours** (default 21:00-08:00 IST) and **per-customer daily cap** (default 3): confirm or change.
13. **Delay precision.** Is a floor of about 5 minutes (GitHub cron drift) acceptable, or should the dispatcher move to pg_cron + an HTTP call (needs `pg_net`, a new extension)?
14. **Family members** (`customer_members`): do events go to the primary customer mobile only, or also to member mobiles?
15. **Supplier flows.** Keep the RFQ/PO WhatsApp path bespoke in release 1 (my proposal), or fold it in?
16. **Who is "sales person"** for events when the lead is unassigned (round-robin switch OFF per memory)? Fall back to master?

## 15. Proposal awaiting approval (live write, not done)

Create, as `is_test = true`:

1. Customer **"jeshee test trigger"**: org Sirah Digital, area Pallavaram, mobile = the test number (ending 6740), `source = other`, notes "automation test fixture, do not delete".
2. Allow-list row for that number; `automation_send_mode` left at `live` until you approve the first test run, then `allowlist_only` for the run window.
3. Test technician and test sales person (or reuse existing test accounts, your call in question 10).

Nothing is created until you approve. Next step after approval: Phase 0 questions answered, then I implement Phase 1 in a worktree off the merged lead stack and stop for review before any send.
