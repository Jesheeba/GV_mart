# Dispatcher v2: what was built, and the deploy package for approval (2026-10-12)

Status: **BUILT AND TESTED LOCALLY. NOT APPLIED. NOT DEPLOYED.** Nothing here has touched the live database or any live function. This document is the package the owner approves before anything goes live. Design intent and evidence: `plan-dispatcher-fix.md`.

Branch `feat/dispatcher-fix`, cut from `origin/main` at `c88a8d2` (contains the F-08 test-mode gate). Migration numbers `20261016300000` and `20261016310000`; live `schema_migrations` max on 2026-10-12 was `20261016110000` (AMC and flag migrations, not yet on `origin/main`); re-check both immediately before applying.

## 1. What was built (plan items a to j)

| Plan item | Where | Notes |
|---|---|---|
| (a) schema | `migrations/20261016300000_wa_dispatch_v2_schema.sql` | status CHECK widened (`pending`, `skipped_no_template`); `wasi_message_id`, `delivery_status`, `delivered_at`, `read_at`, `failed_at`, `claimed_at`, `wasi_response`, `template_name`, `template_params`; `whatsapp_contacts` + `wa_touch_contact()` (last 10 digits, backfilled); `whatsapp_wasi_templates` (mirror); `whatsapp_event_templates` (mapping); `settings.wa_dispatch_v2_enabled` (default OFF) |
| (a) trigger step | `migrations/20261016310000_wa_dispatch_v2_pending_normalisation.sql` | one BEFORE INSERT trigger; inert unless the flag is on |
| (b) sendMessage | `_shared/wa-send-core.ts` (pure), `_shared/whatsapp.ts` (adapter) | insert row first, then send; template rows send `template` + `params` (+ `headerMediaUrl` only for a media header), never `body`/`type:"text"`; `meta_message_id` becomes `wa_message_id`, Wasi's `id` becomes `wasi_message_id`; 201 + `meta_message_id` is the only `sent`; 201 without it stays `pending` (`accepted_no_message_id`) |
| (c) claim | `_shared/wa-dispatch-v2.ts`, `_shared/wa-milestone-dispatch-core.ts` | atomic `UPDATE ... WHERE status='pending' AND claimed_at IS NULL`; no automatic reclaim of stale claims |
| (d) webhook | `_shared/wasi-webhook.handler.ts`, `wasi-webhook/index.ts` | signature before any write; `delivery_status` only, monotonic; `failed` stores Wasi's error; 200 immediately, processing through `EdgeRuntime.waitUntil`; template status events update the mirror |
| (e) no template yet | `executeSend` | outside the 24 h window (`whatsapp_contacts.last_inbound_at`) a notification with no approved template becomes `skipped_no_template`; inside it, free text is allowed |
| (f) mapping | `whatsapp_event_templates` + `whatsapp_wasi_templates` | **no rows seeded**: nothing sends as a template until the owner adds a mapping row for an approved template. Names must differ per language (`_en` / `_ta`); a name that exists twice on Wasi is refused |
| (g) PII | `wasi-error-detail.ts`, `wa-send-core.ts`, handler | wamids redacted from every log and stored error; the stored Wasi response drops `meta_message_id`, `to`, `client_id`; the old "UNVERIFIED list_reply" full-payload log was removed |
| (h) tests | see section 3 |
| (i) deploy order, rollback | section 4 to 6 |
| (j) F-08 | `executeSend` | the gate runs after the row exists and before any HTTP; blocked sends update the same row to `failed`, `retried_at` set, `WA_SEND_BLOCKED` audit row |

UI: Failed Sends now also lists `skipped_no_template`, deliveries Meta later rejected, and claimed-but-unfinished rows ("stuck sending"), with a State column (EN + TA strings; Tamil is a draft in `tamil-review-dispatcher.md`).

### Deviations from the plan (and why)

1. **Pending normalisation is one trigger, not edited trigger bodies.** `whatsapp_outbox` is written by about 10 definer functions across 8 migrations; re-creating them risks clobbering (the shared-RPC collision problem). One `BEFORE INSERT` rule gives the same result for every present and future writer and is switched by the flag. Only dispatched reference types (`service_ticket`, `service_visit`, `invoice`, `purchase_quote_request`) are normalised; `purchase_order` rows are never dispatched (separate known gap) and are left as written.
2. **The "11 optimistic rows" no longer exist live.** The outbox now holds 3 rows (2 inbound, the probe). The marking `UPDATE` is kept, guarded by its predicate, and is a no-op today.
3. **Retry model.** v2 re-queues the same row (never a second row), and only for 409 `conflict` (once) and a pre-send network error (up to 3). Everything else is terminal and visible in Failed Sends.
4. **Flag.** Everything is gated by `settings.wa_dispatch_v2_enabled` (OFF). With it off, `sendMessage`, the dispatcher and the retry pass behave exactly as today.

## 2. What the owner still has to provide (nothing sends as a template until these exist)

- Approved Wasi templates (already approved: `shipping_update`, `hello_world`, `appointment_reminder`, `invoice_document`, `po_quote_request_doc_v3` (duplicate name; the owner is asking Wasi to delete one)). To be created and submitted: `gvm_invoice_issued_en/_ta`, `gvm_service_booked_en/_ta`, `gvm_technician_assigned_en/_ta`, `gvm_technician_arrived_en/_ta`, `gvm_service_completed_en/_ta`, `gvm_feedback_request_en/_ta`, `gvm_amc_expiring_en/_ta`.
- One `whatsapp_event_templates` row per (event, language) once its template is approved, e.g. `milestone.booked`, `en`, `gvm_service_booked_en`, `{"name":"name","ticket_ref":"ticket_ref","complaint":"complaint"}`. Variable keys the dispatcher can supply: `name`, `customer_name`, `ticket_ref`, `complaint`, `technician`, `slot`, `appointment_time`, `summary_link` (needs `WA_PUBLIC_APP_URL`), `invoice_no`, `invoice_number`, `invoice_date`, `amount`, `link` (customer app home; there is no per-invoice page yet), `supplier_name`, `pdf_url`; scheduled jobs add `product`, `expiry_date`, `days`, `rating_link`.
- Optional function secret `WA_PUBLIC_APP_URL` (public app origin) for the link variables.

## 3. Tests

| Suite | What it proves |
|---|---|
| `wa-send-core.test.ts` | window math; decision rule; template request (params, media header, missing param); 201 with id / without id / status failed; each 409 code; `conflict` retried once; 502 `metaError` + `fbtrace_id`; network error vs timeout; insert-before-HTTP; skipped never calls Wasi; reply vs notification; language fallback; F-08 blocked on the same row; stub never `sent`; no wamid in any stored field |
| `wa-dispatch-v2.test.ts` | duplicate dispatch race: two workers, each row sent exactly once; lost claim; no recipient; attempt cap; thrown send leaves the claim |
| `wasi-webhook.handler.test.ts` | signature required before any write (status, received, template status); monotonic delivery; failed stores error; unknown id 200 no write; fast 200 with deferred processing; store errors swallowed without identifiers |
| `whatsapp.v2-routing.test.ts` | flag read and fallback; flag off = today's path; flag on stub stays pending; real transport sends the exact approved template request and stores the wamid; no wamid in logs; duplicate template name refused; F-08 block |
| `wa-event-format.test.ts` | IST slot/date, rupees, short ref, Wasi template mapper |
| `supabase/tests/wa_dispatch_v2.test.sql` | status CHECK; `wa_touch_contact`; normalisation off/on; milestone trigger output is `pending`; atomic claim; privileges. **Written, not run**: it needs a database (a rolled-back transaction on the live DB, which needs approval) |

Local result on this branch: full vitest run `464 passed, 9 skipped, 0 failed`, `tsc -p tsconfig.app.json` clean, `oxlint` no new findings.

## 4. Exact steps, in order (each live step waits for approval)

Preflight (read-only): `supabase projects list` confirms the project; `origin/main` and `schema_migrations` re-checked; function bundles for rollback saved (the currently deployed `wasi-webhook` v43, `whatsapp-webhook` v50, `wa-dispatch-now` v11, `wa-milestone-dispatch` v13, `wa-scheduled-tasks` v22 correspond to `origin/main` at the 2026-10-06 deploy plus nothing else).

1. **Dry run of the SQL test** (approval needed): `BEGIN; <migration 1>; <migration 2>; <wa_dispatch_v2.test.sql>` against the live DB; it raises at the end and rolls back. Expect every line `ok`.
2. **Apply migration 1** `20261016300000_wa_dispatch_v2_schema.sql` (additive; flag OFF; the app is unchanged).
3. **Deploy functions**: `wasi-webhook`, `whatsapp-webhook`, `wa-dispatch-now`, `wa-milestone-dispatch`, `wa-scheduled-tasks`, from this branch (cut from `origin/main`), not from local `main`. With the flag OFF their behaviour is today's; the new `wa_touch_contact` call starts recording `last_inbound_at`; the daily job starts mirroring Wasi's template list.
4. **Apply migration 2** `20261016310000_wa_dispatch_v2_pending_normalisation.sql` (inert until the flag is on).
5. **Verify with the flag still OFF**: send "hi" from the test number, expect the normal greeting and a `whatsapp_contacts` row; run the template sync once and check `whatsapp_wasi_templates` (15 rows, one duplicated name flagged).
6. **Turn the flag ON** (approval needed): `update settings set wa_dispatch_v2_enabled = true`. Within 30 seconds every function instance sees it.
7. **Controlled test** (approval for each send, test customer's number only, approved template only): add one `whatsapp_event_templates` mapping for an approved test template, trigger one event for the test customer, and check the single outbox row: `pending` then `sent`, `wa_message_id` = WhatsApp id, `wasi_message_id` = Wasi id, then `delivery_status` `delivered`/`read` from the webhook.
8. **Observe** for a day: Failed Sends should show `skipped_no_template` rows for events with no template and nothing else unexpected.

## 5. Rollback

- **Fastest, no deploy:** `update settings set wa_dispatch_v2_enabled = false`. The trigger goes inert, `sendMessage` / dispatcher / retry pass return to today's behaviour within 30 seconds. Rows already `pending` are still picked up by the legacy dispatcher (it selects `wa_message_id is null and retried_at is null`).
- **Functions:** redeploy the previous bundles saved in preflight.
- **Triggers:** `supabase/rollbacks/20261016310000_wa_dispatch_v2_pending_normalisation.rollback.sql`.
- **Schema:** `supabase/rollbacks/20261016300000_wa_dispatch_v2_schema.rollback.sql` is a last resort: it discards delivery history, the contacts table and the template mapping. Leaving the additive schema in place is the recommended rollback.

## 6. Risks and open items

| # | Item |
|---|---|
| 1 | **Stuck `pending` rows** (claimed, never finished) need a human by design; they show in Failed Sends. |
| 2 | **Webhook live behaviour is unverified.** The probe message's status events did not touch the row on 2026-10-12 (cause undetermined: not delivered, rejected, or the old CHECK failure). The new handler fixes the CHECK problem; whether Wasi actually delivers `message.status` to our URL must be checked in Wasi's delivery log (open task for the owner). |
| 3 | **`message_template_status_update` payload shape is unconfirmed**; the handler is defensive (needs `waba_id`, a name and a status) and the daily sync is the source of truth. |
| 4 | **No invoice page or PDF yet**; the invoice `link` variable is the customer app home. |
| 5 | **`purchase_order` sends are still never dispatched** (pre-existing gap, out of scope). |
| 6 | The flag is changed with SQL; a switch in the Automation page is a small follow-up (the F-08 `WaTestModeSwitch` is the pattern). |
| 7 | **Tamil strings** in Failed Sends are drafts pending native review. |
| 8 | **Customer language** is `profiles.language` via the customer's login; customers without a login fall back to English. |
