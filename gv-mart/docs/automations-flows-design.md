# Automations screen: design (enquiry video flow)

Status: DESIGN ONLY (2026-10-13). Accepted by the owner with the decisions in section 7. No code, no migration, no database write, no WhatsApp send, no template submission was done. Nothing here is built.

Base: `origin/main` at a08819b, plus the Stage B hand-off on `feat/automation-phase3b` (not applied). The live database was **not** queried; "what is applied live" and "the video tables are empty" come from the migration docs and the owner's brief.

Related: `docs/plan-automation-flows.md` (the wider event/rule design), `docs/automation-phase3-plan-revised.md` (Phase 3 plan, branch `feat/automation-phase3b`), `docs/wasi-template-submission-sheet-wave1.md` (template conventions).

Naming: the new screen is **Automations**. The existing keyword bot screen keeps the name **Flows** and is unchanged.

## 1. One-page design summary

**Idea.** The master picks a trigger from the code-owned catalogue, adds an optional condition, and the action sends one approved WhatsApp template. Each automation is a named wrapper (`automation_flow_defs`) around one `automation_rules` row. The screen sits on the engine that already exists; there is no engine rewrite.

**First automation.** Trigger **Enquiry created** (event `lead.created`, condition kind is `product` or `spare`) sends the customer the template `gvm_enquiry_video` with the video link of the enquired product or spare as a body variable (Wasi allows no dynamic button parameters).

**What the master sees.** A list with name, trigger, action, on/off, mode (Test / Watching / Live), last run, counts and attention badges; a three-step create wizard; a Go Live checklist; a history drawer; archive and restore (section 5).

**New pieces.**
1. Video storage for spares (`spare_videos`, mirroring `product_videos`).
2. A hand-off video resolver, the `lead` hand-off ref type and the audited state `skipped_no_video`, plus the master in-app alert.
3. Dispatcher variables `video_url` and `item_name`.
4. Master-only RPCs: create/save, toggle, archive, restore, and a live-guard in `automation_rule_save`.
5. The Automations screen (en and ta strings).
6. Template `gvm_enquiry_video` and its mapping row.

**Safety.** Test, then Watching (shadow), then Live, with a checklist at the Live step. Every existing gate stays (section 3). The live-guard adds a template-approved check at save time.

**Not in version 1.** Hard delete, free-form actions (task, assign), staff WhatsApp, multi-item links, custom events, staff-typed leads.

**Size.** About 8 to 10 working days of build, excluding the blockers in section 6.

## 2. Data findings

### 2.1 What exists on origin/main

- **Tables:** `automation_events` (catalogue), `automation_flow_defs` (name, `is_active`), `automation_rules` (immutable versions), `automation_queue`, `automation_audit` and `automation_event_log` (append-only), `automation_errors`.
- **Rules:** status `test_only`, `shadow`, `live` or `paused`; event, recipient role, channel (`whatsapp`, `in_app`, `both`), template name, language, delay, cooldown, `max_fires`, plus Stage A `message_class`, `respect_quiet_hours`, `max_defer_hours`. Conditions are key=value or any-of matches on the event payload text.
- **Write path:** `automation_rule_save()` only. Master-only, writes a `config_changed` audit row. There is no client write path to flows or rules.
- **Lead events:** a trigger on `leads` emits `lead.created`, and then `product_enquiry.submitted` (kind `product`) or `spare_enquiry.submitted` (kind `spare`). Payload keys: `kind`, `source`, `status`, `enquiry_type`, `mobile`, `sales_person_id`. It does **not** carry `product_id` or `spare_id`.
- **What an action does today:** queue one WhatsApp template and/or an in-app notification. Phase 2 and Stage A only write `dry_run` rows; real sending is the Stage B hand-off to `whatsapp_outbox` (not applied).
- **Admin UI:** none for the new rules (no reference to `automation_rules` or `automation_rule_save` in `src/`). The existing Flows tab is the old keyword bot (`automation_flows`: enquiry topic to send_video, quotation or link) and is a separate system.

### 2.2 Video data

| Item | Storage today | Gap |
|---|---|---|
| Product | `product_videos` (many per product, `sort_order`, `is_active`) | empty |
| Spare | none | needs `spare_videos` (or a `video_url` column) |
| Topic video | `video_library` (keyed by `enquiry_type`, not by item) | empty |

Which item the enquiry is about:
- App and WhatsApp enquiries go through `_submit_customer_enquiry_internal`, which writes `leads.product_id` or `leads.spare_id` (the first item) in the same INSERT, so the AFTER INSERT trigger sees them.
- Staff-typed leads (New Lead form) have only a product type and free-text notes, no item. Version 1 skips them (decision, section 7).
- When an enquiry merges into an existing open lead, no new lead is created and `lead.created` does not fire (known edge case; the customer is not messaged for the merged item).

### 2.3 How the link reaches the message

1. Trigger: `lead.created`, condition kind in (`product`, `spare`), source in (`customer_app`, WhatsApp).
2. At hand-off, a SQL helper reads the lead's `product_id` or `spare_id` (first item only).
3. It picks the first active video by `sort_order` from `product_videos` or `spare_videos`, otherwise the `video_library` row for the lead's `enquiry_type`.
4. It validates `https`, trimmed, no whitespace, short (template hygiene: about 60 characters per variable, so short links such as youtu.be).
5. It stores `video_url` and `item_name` in the queue row's `context`, which the hand-off copies into `whatsapp_outbox.payload`.
6. `wa-automation-vars.ts` maps them to the template variables `video_link` and `item_name`.

Nothing found: the row ends as the audited state `skipped_no_video`, is never sent with an empty variable, and the master gets an in-app alert ("no video for X").

Code changes needed: `lead` added to `automation_handoff_ref_types` (today only service_ticket, service_visit, invoice); a lead branch in the dispatcher's `resolveEventContext`; new CHECK values for the audit decision and queue state.

## 3. Safety findings: where each rule is enforced

| Rule | Enforced where |
|---|---|
| Shadow/test first | Rule status. `test_only` fires only for test subjects (`skipped_test_only`). `shadow` records queue and audit but is never handed over. Hand-off re-checks the rule is `live`. |
| Template approved before live | Hand-off needs an active `whatsapp_event_templates` mapping pointing to an `approved` row in `whatsapp_wasi_templates`, else `skipped_no_template`. **Proposed addition:** `automation_rule_save` refuses `live` unless that check passes. |
| Dispatcher flag | `automation_enabled` at emit and hand-off. `wa_dispatch_v2_applies(org, mobile)` at hand-off (`blocked_not_in_dispatch_scope`), so a real customer can never reach the legacy free-text path. |
| Opt-out (STOP) | Webhook writes `customer_comm_prefs` (STOP = non-job, STOP ALL = everything). `_automation_is_opted_out` at emit and again at hand-off, keyed by number. This flow is non-job. |
| Quiet hours | `_automation_next_allowed` holds `fire_at` to 08:00 IST for messages due 21:00 to 08:00 (settings, per-rule flag). Only `technician.on_the_way` and OTP are exempt. |
| Daily cap of 3 non-job | Counted at emit per customer per IST day, same mode only. Over the cap is `deferred_daily_cap`, released next window, expiring after 72 h. |
| Main customer's mobile only | Resolver uses `customers.mobile`. The payload mobile is used only when there is no customer record; for this flow that case is now excluded (section 7). |
| `is_test` | `leads.is_test` kept in step with `customers.is_test` by trigger. A test subject can only reach a flagged test number or an allow-listed number (emit and hand-off). The F-08 test-mode allow-list is also enforced at the transport `sendMessage`. |

## 4. Draft templates (not submitted)

Name `gvm_enquiry_video_en` / `gvm_enquiry_video_ta`. Class: non-job (to be added to `automation_template_classes`). Header: none. Buttons: none. Footer: `Reply STOP to stop these messages`.

**Category: OPEN.** Recommended **Marketing**, because a promotional product video is the textbook Marketing case and mislabelling invites re-categorisation or a `consent_required` 409. Whether Marketing is acceptable, or Utility is defensible, depends on the client's answer to question 4 (section 7).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `item_name` | product or spare name, cleaned | Aquaguard RO water purifier |
| `video_link` | `product_videos`, `spare_videos` or `video_library` | https://youtu.be/AbCdEfGhIjK |

**English** (`gvm_enquiry_video_en`, language `en`):

`Hi {{customer_name}}, thank you for your enquiry about {{item_name}}. Here is a short video that shows the details: {{video_link}} . Reply to this message if you would like a quotation or have any questions.`

**Tamil** (`gvm_enquiry_video_ta`, language `ta`) **DRAFT: NOT REVIEWED by a Tamil speaker. Do not submit before review.**

`வணக்கம் {{customer_name}}, {{item_name}} குறித்த உங்கள் விசாரணைக்கு நன்றி. விவரங்களைக் காட்டும் சிறு வீடியோ இதோ: {{video_link}} . விலைப்பட்டியல் வேண்டுமெனில் அல்லது ஏதேனும் கேள்விகள் இருந்தால் இந்த செய்திக்குப் பதிலளிக்கவும்.`

Rules followed: no variable at the start or end of the body, none adjacent, every variable has an example, named variables.

**Mapping row (after approval):** `event_key = gvm_enquiry_video`, one row per language, `param_map = {customer_name: customer_name, item_name: item_name, video_link: video_url}`. Confirm the keys against `body_param_examples` after approval.

## 5. The Automations screen

**List, one row per automation:** name; trigger in words ("Enquiry created · kind is Product or Spare · from the app or WhatsApp"); action ("Send WhatsApp: Enquiry video (EN / TA)"); on/off switch (On = `live` or `test_only`, Off = `paused`); mode chip (Test = test customers only, Watching = shadow, Live); last run (latest event or audit time for the rule); counts over the last 7 days (sent, skipped, blocked, with a why-skipped breakdown); attention badges ("template not approved", "N enquiries had no video").

**Create, three steps:** (1) When: trigger from the catalogue with typed conditions. (2) Then: approved template and language, with a preview using sample values. (3) Name it and save; a new automation always starts in Test.

**Go Live:** a checklist button, enabled only when the template is approved, the mapping is active, and one test run succeeded for the test customer.

**History drawer:** audit history (masked numbers only) and version history (who, when, what changed).

**Delete is archive.**
- Rules and audit are immutable, so nothing is deleted.
- Archive sets the flow's `is_active = false` through a new master RPC (there is no client write path today) and saves a new `paused` rule version. No engine change.
- Archived automations sit behind an "Archived" filter. **Restore** creates a new version in Test, never straight to Live.
- There is no hard delete.

**Permissions:** only the master creates, switches, archives and restores (`automation_rule_save` is already master-only).

## 6. Size, risks, blockers

**Build: about 8 to 10 working days.**

| Item | Days |
|---|---|
| `spare_videos` storage plus admin UI | 1 |
| Hand-off `lead` ref type, video helper, `skipped_no_video`, master alert, in-app note to the sales person, rolled-back SQL tests | 1.5 to 2 |
| Dispatcher variables and vitest | 0.5 |
| Flow RPCs (create, toggle, archive, restore, live-guard) with tests | 1.5 |
| Automations screen with en/ta strings | 3 to 3.5 |
| Test-customer end-to-end run and docs | 1 |

**Blockers (outside build time):**
- Stage B is unapplied, and so are the dispatcher flag and per-number scope. The hand-off is not scheduled.
- Template approval by Wasi/Meta, and the Tamil review.
- Product and spare videos have to be loaded.
- **"Starts automatically" is true only up to the queue.** Hand-off is designed for a pg_cron minute tick, but the send depends on dispatcher cadence, and GitHub's `*/5` has fired every 3 to 7 hours. The pg_net scheduler (`feat/wa-cron-pgnet`) is built but held. Until it is applied, the video arrives hours late.

**Risks:**
- Meta may re-categorise the template or reject the variable link.
- A merged enquiry (existing open lead) does not fire `lead.created`.
- `lead.created` and `product_enquiry.submitted` both fire for one lead. The screen offers only "Enquiry created", and the 30-day cooldown is the backstop.
- A WhatsApp enquiry can trigger both the old keyword bot video and this automation (the bot stays unchanged by decision).
- The video message is non-job: STOP blocks it and it uses one of the 3 daily slots.
- Long video URLs exceed the variable length hygiene; short links are required.

## 7. Client questions and decisions

Decisions recorded 2026-10-13 (owner), with the answer to each of the 13 questions.

| # | Question | Decision |
|---|---|---|
| 1 | Staff-typed leads have no item. Send only for app and WhatsApp enquiries, or restore an item picker? | **Version 1 sends only for app and WhatsApp enquiries. Staff-typed leads are skipped.** |
| 2 | Item has no video: skip, send a general topic video, or alert? | **Skip and alert the master in the app.** (No topic-video fallback is sent as a message.) |
| 3 | Enquiry with several items: first only, or one per item? | **First item only.** |
| 4 | Is the video promotional? Have customers agreed to receive promotional messages? (Decides Marketing or Utility, and whether opt-in is needed.) | **OPEN, with the client.** |
| 5 | Is it acceptable that STOP stops this and it counts toward the 3 a day? | **Yes. STOP and the daily cap of 3 apply.** |
| 6 | A 10 pm enquiry gets its video at 8 am next day: acceptable? | Standing rule applies (quiet hours 21:00 to 08:00 IST, held until 08:00); no objection recorded. |
| 7 | Same customer, same item again: send again? | **At most once per item per 30 days** (cooldown 720 hours per customer and item). |
| 8 | Lead with no customer record: send to the typed number? | **No send to a lead that has no customer record.** |
| 9 | Who supplies and maintains the videos, and in which languages? | **OPEN, with the client.** |
| 10 | Should the sales person get an in-app note? | **Yes.** |
| 11 | Language and Tamil reviewer. | **The customer's preferred language, else English.** The Tamil reviewer is still to be named; Tamil templates are not submitted before review. |
| 12 | Keep the old keyword video bot? | **Yes, unchanged. It keeps the name "Flows".** |
| 13 | Who creates and archives? | **Only the master.** |

Also decided: the screen is named **Automations**; there is **one trigger, "Enquiry created"**, not two.

Still open for the client:
1. Whether customers have agreed to receive promotional messages (decides Marketing or Utility; section 4).
2. Who supplies the videos and in which languages (a video per language would need a language column on the video tables, which this design does not yet include).

### Consequences of the decisions for the build

- Condition on source: the trigger fires only for `source` values of the app and WhatsApp (the exact `leads.source` values must be confirmed in the code before the build, since `submit_customer_enquiry` writes `customer_app`).
- The "no customer record" rule means the hand-off must refuse a lead whose `customer_id` is null (audited as `skipped_no_recipient`), not fall back to the payload mobile.
- The per-item 30-day cooldown needs the cooldown scoped to customer and item (`product_id` or `spare_id`), not customer alone, so the occurrence key and cooldown lookup must include the item. The Stage A cooldown counts per customer across subjects, so this needs a small engine change or a per-item occurrence key.
- The in-app notes (master alert on no video, sales person note on send) use the existing `notifications` table.
