# Automations screen: design (enquiry video flow)

Status: DESIGN ONLY (2026-10-13). Accepted by the owner with the decisions in section 7. No code, no migration, no database write, no WhatsApp send, no template submission was done. Nothing here is built.

Base: `origin/main` at a08819b, plus the Stage B hand-off on `feat/automation-phase3b` (not applied). The live database was **not** queried; "what is applied live" and "the video tables are empty" come from the migration docs and the owner's brief.

Related: `docs/plan-automation-flows.md` (the wider event/rule design), `docs/automation-phase3-plan-revised.md` (Phase 3 plan, branch `feat/automation-phase3b`), `docs/wasi-template-submission-sheet-wave1.md` (template conventions).

Naming: the new screen is **Automations**. The existing keyword bot screen keeps the name **Flows** and is unchanged.

## Two questions only the client can answer

Nothing is built or submitted until these are answered. Please answer each with yes or no, plus the detail asked.

1. **Have your customers agreed to receive promotions from you?** Yes or no. (For example: do they tick a box, sign a form, or tell you in person that you may send them offers and product information on WhatsApp?)
   - If **yes**: we submit the message as a Marketing template and send it to customers who agreed.
   - If **no**, or you are not sure: we cannot send it as a promotion. We would have to reword it as a plain reply to the enquiry the customer themselves made, and Meta may still treat it as a promotion and refuse it. Nothing is sent until this is settled.

2. **Who supplies the product and spare videos, and in which languages?** Please tell us (a) who makes and uploads them, (b) whether you have one video per product and per spare, and (c) the language: **English only, Tamil only, or both Tamil and English?**
   - If **English only** or **Tamil only**: no change to the design below.
   - If **both**: the design changes (section 9). Today there is no language column on any video table, so a second video for the same item is indistinguishable from the first, and a Tamil customer could be sent the English video or the other way round.

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

Which item the enquiry is about (**corrected 2026-10-14, see section 8.2**):
- The customer app calls `submit_customer_enquiry`, which goes through `_submit_customer_enquiry_internal`. It writes `leads.product_id` or `leads.spare_id` (the first item) in the same INSERT, so the AFTER INSERT trigger sees them.
- The WhatsApp bot's spare enquiry goes through the same internal function but passes `p_items = []`, so it carries **no item**. It also writes the source `customer_app`, not `whatsapp`.
- A raw WhatsApp "sales" entry (`_whatsapp_lead_upsert`) writes source `whatsapp`, kind NULL and no item.
- Staff-typed leads (New Lead form) have a product type, free-text notes and a chosen source and kind, but no item. Version 1 skips them (decision, section 7).
- When an enquiry merges into an existing open lead, no new lead is created and `lead.created` does not fire (known edge case; the customer is not messaged for the merged item).

### 2.3 How the link reaches the message

1. Trigger: `lead.created`, condition kind in (`product`, `spare`) and `has_item` is true (section 8.2: the source value cannot tell the channel apart, the item can).
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
| 1 | Staff-typed leads have no item. Send only for app and WhatsApp enquiries, or restore an item picker? | **Version 1 sends only for app and WhatsApp enquiries. Staff-typed leads are skipped.** *Finding 2026-10-14: WhatsApp enquiries currently carry no item, so in practice version 1 reaches app enquiries only (section 8.2).* |
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

Superseded by sections 8 and 9, which specify each one exactly. In short: the source condition is replaced by an item condition (8.2); the no-customer-record refusal moves to emit time (8.3); the 30-day cooldown becomes per customer and per item (8.1); the in-app notes use the existing `notifications` table.

## 8. Specifications (added 2026-10-14)

Nothing here is built or applied. References are to the migrations on `origin/main` (Stage A, `20261018120000`) and `feat/automation-phase3b` (hand-off, `20261018130000`). The live database was not queried and no test was run.

### 8.1 The 30-day cooldown, per customer AND per item

**Today.** In `automation_emit` the cooldown (S6) is: a queue row exists with the same `rule_key`, the same `customer_id`, the same `mode`, a counted state, and `created_at` inside the window. It is scoped to rule and customer only. The idempotency key is `rule_key | customer | subject | occurrence | mode | recipient`; the subject is the lead, so the key only stops a replay for the same lead.

**Why the occurrence key is not the answer.** The key still contains the lead id, so a second lead for the same item gets a different key and is never suppressed. The cooldown is the place for it.

**What changes** (one new migration, replacing `automation_emit` and `automation_rule_save` again, as Stage A did):

| # | Where | Change |
|---|---|---|
| 1 | `automation_queue` | new nullable `item_key text`; index on `(org_id, rule_key, customer_id, item_key, created_at)` |
| 2 | `automation_rules` | new `cooldown_per_item boolean not null default false`, so the review and AMC rules are untouched |
| 3 | `automation_rule_save` | new parameter `p_cooldown_per_item`; the old signature is dropped and recreated with the same grants in the same transaction, as 3A did |
| 4 | `_trg_automation_emit_lead` | payload gains `product_id`, `spare_id`, `has_item` and `item_key = coalesce(product_id, spare_id)::text` |
| 5 | `automation_emit`, cooldown query | add `and (not r.cooldown_per_item or v_item is null or q.item_key = v_item)`, with `v_item := nullif(v_payload ->> 'item_key', '')` |
| 6 | `automation_emit`, every `insert into automation_queue` (three sites: normal, deferred, shadow path) | store `item_key = v_item` |
| 7 | the counted-state lists | add the new state `skipped_no_video` to every excluded list (section 8.4) |
| 8 | the rule | `dedupe_cooldown_hours = 720`, `cooldown_per_item = true` |

**When the item is unknown.** Per-item with no item falls back to customer-wide, so it is never weaker than today. In version 1 an item-less lead does not reach the cooldown (condition `has_item`).

**What breaks if it is wrong:**
- Cooldown left customer-wide: a customer who enquires about a second, different item inside 30 days gets no video for it, silently.
- Cooldown too narrow, or `item_key` not stored at one of the three insert sites: the same item's video goes out again, and each one uses a slot of the daily cap of 3.
- `skipped_no_video` not excluded from the counted states: a lead with no video blocks that item for 30 days even after the master uploads the video, and the master's alert never clears. A missing exclusion in the daily-cap count burns a slot for a message that was never sent.
- `item_key` read from `leads.product_id` at count time instead of stored at queue time: a staff edit of the lead rewrites history. Hence it is stored.
- A failed Wasi send still counts toward the cooldown (existing behaviour for every rule, because the row was handed over). A video that failed delivery is not retried for 30 days. Not changed here; the master should know.

**A finding that matters more than the cooldown.** `_find_recent_open_lead` merges a customer's new enquiry into their open lead (status not won or lost, created in the last 30 days). A merge creates no new lead, so `lead.created` does not fire and no video goes out. A customer who enquires about product A and then product B within 30 days gets a video for A only. The per-item cooldown is therefore reachable only when the earlier lead was already won or lost. If the client wants a video for the second item, the design needs a new event, for example `enquiry.item_added`, emitted when a merge adds a line item (section 10, item A).

### 8.2 `leads.source`: the exact values, and why the condition changes

Confirmed from the migrations and the bot code:

| Fact | Evidence |
|---|---|
| `leads.source` is plain text holding a key from `lead_sources`; seeded system keys: `field`, `customer_app`, `whatsapp`, `walk_in`, `referral`, `other` | `20261005130000_dynamic_lead_sources.sql` |
| Customer app product or spare enquiry: source `customer_app`, kind `product` or `spare`, item set | `_submit_customer_enquiry_internal` (`20260819130000`) |
| **WhatsApp bot spare enquiry: source `customer_app`** (hard-coded in the shared function), kind `spare`, **`p_items = []`, so no item** | `wa_create_spare_enquiry`; `whatsapp-handle-message.ts` action `create_spare_enquiry` |
| WhatsApp sales entry: source **`whatsapp`**, kind NULL, no item | `_whatsapp_lead_upsert` (`20260831120000`), called by `wa_create_lead` |
| Staff-typed lead: source chosen by the staff member (default `other`, but `customer_app` or `whatsapp` can be picked), kind chosen, no item | `NewLeadForm.tsx` |
| The bot never creates a `product` kind enquiry | `whatsapp-handle-message.ts` passes `p_kind: "spare"` only |

**Consequences:**
1. `source = 'whatsapp'` never carries kind `product` or `spare`, so a condition on it matches nothing.
2. `source = 'customer_app'` cannot tell an app enquiry from a WhatsApp one, and staff can type it by hand.
3. The source value is not a usable test for "app or WhatsApp, not staff-typed". The reliable test is the item: only the customer-facing enquiry functions write `product_id` or `spare_id`, and the New Lead form has no picker.
4. **Version 1 therefore reaches app enquiries that name an item.** WhatsApp enquiries reach no one, because the bot does not capture an item. A video for a WhatsApp enquiry needs the bot to resolve a product or spare from the customer's words, which the zero-AI keyword bot does not do. That is new bot work and is not in this design (section 10, item B).

**Condition to build against:** kind in (`product`, `spare`) and `has_item` is true. `source` is left out of the rule. Nothing is built against a guessed source value.

### 8.3 The no-customer-record refusal

**Today.**
- Emit (`automation_emit`): for a customer recipient with no customer record, the payload `mobile` is used (the S7 fallback). A queue row is created and audited `dry_run` with a masked number.
- Hand-off (`automation_handoff_due`): already refuses it. A null `customer_id` gives no mobile, so the row becomes `skipped_no_recipient`, and test H7 covers it.
- So nothing can be sent, but the row looks like a would-send, and a shadow period would overstate reach.

**Specification.**
1. **Emit, customer recipient, no customer record** (null customer id, or the customer row not found for the org): no queue row; audit `skipped_no_recipient` with `detail = {"reason": "no_customer_record"}`. The payload `mobile` is not used. `skipped_no_recipient` is already allowed by the CHECK lists, so there is no new decision value.
2. The `_mobile_key(v_payload ->> 'mobile')` branch for `recipient_role = 'customer'` is removed. The main-number-only rule (S7) is unchanged.
3. **Hand-off:** unchanged. It stays as the second, independent refusal.
4. **Scope:** every rule with a customer recipient, not only this one. That is a deliberate behaviour change (the hand-off already behaves this way), so the Phase 2 and 3A engine tests must be re-run. I did not run them. Any test that emits with a null customer and relies on the payload number must be reviewed; S7 in `automation_phase3a_engine.test.sql` and H7 in `automation_phase3b.test.sql` do not depend on the fallback.
5. **Reach in version 1:** an app enquiry always has a customer, so this rarely triggers. It protects against future sources and against a customer row removed after the lead was created.
6. **Visible to the master:** shown in the history drawer as "No customer record" and counted under why-skipped. No alert, because it is not actionable per lead.

**What breaks if wrong:** left as today, a shadow period shows sends that can never happen; done at emit but removed from the hand-off, a queue row created before the change can reach the dispatcher. Both stay.

### 8.4 State lists that must change together

The excluded-state list is a literal array repeated in at least four places in the hand-off version of the engine (max-fires count, cooldown, daily-cap count, deferred release). Adding `skipped_no_video` to one and missing another is the failure in section 8.1. Specification: one helper `_automation_state_is_counted(text)`, and every site calls it. If that is judged too large, all four sites are updated in one migration and a test asserts all four.

## 9. If the videos are in both Tamil and English

The answer to client question 2 changes the design. There is no language column on `product_videos` or `video_library`, and `spare_videos` does not exist yet.

| Area | Change |
|---|---|
| Storage | New nullable `language text check (language in ('en','ta'))` on `product_videos`, `spare_videos` and `video_library`. NULL means "any language", so every existing row keeps working. |
| Admin forms | A language selector on each video form; the list shows the language; one item can have an English and a Tamil video at the same time. |
| Resolver | The hand-off helper takes the message language (already resolved: preferred language, then login language, then rule language, then English) and picks, in order: the video in that language, a language-neutral (NULL) video, the English one. It never skips just because the Tamil video is missing. |
| Master alert | Distinguishes "no video" from "no Tamil video, English sent". |
| Customer app | The product page lists all active videos today. Existing rows are NULL, so nothing changes; showing only the customer's language is a separate, optional choice. |
| Template | No change: the same `gvm_enquiry_video_en` / `_ta` pair. The video language is independent of the body language but should match. |
| Tests | One Tamil-customer case and one fallback case added. |
| Size | About +1 working day on the 8 to 10 day estimate. |

If the answer is English only or Tamil only, none of this is built.

## 10. Needs a decision that is not the client's

| | Question | Why it matters |
|---|---|---|
| A | A customer's second enquiry within 30 days merges into the open lead and sends no video (section 8.1). Accept it, or add an `enquiry.item_added` event? | Accepting keeps version 1 simpler, and makes the per-item cooldown nearly unreachable. |
| B | The WhatsApp bot captures no item (section 8.2). Accept "app only in version 1", or add item capture to the bot? | The decision "app and WhatsApp" cannot be met without bot work. |
| C | Apply the no-customer-record refusal to every customer rule (section 8.3)? | A deliberate behaviour change; the Phase 2 and 3A tests must be re-run. |
