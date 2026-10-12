# Dispatcher v2: live state and handoff (2026-10-12, written ~19:50 IST)

Purpose: give the tab that now owns the dispatcher (worktree `GV_mart_dispatcher2`, branch `feat/dispatcher-v2`) an exact record of what is live, how to roll it back, and what must be checked before the flag goes ON. No secrets, full numbers or wamids are recorded here.

## 0. Who did what (read this first)
* The migrations and function deploys below were applied from the worktree **`GV_mart_dispatcher`, branch `feat/dispatcher-fix`** (commits `872b164`, `be30173`, `ab978e2`, `8932b97`, execution log in `5665f4f`, file `docs/plan-dispatcher-fix-deploy.md` section 7). That is the previous dispatcher session's work.
* The security/go-live tab that wrote THIS document (worktrees `GV_mart_secfix`, `GV_mart_dispatcher2` for read-only verification) **did not apply any migration and did not deploy any function.** Everything in sections 1 and 2 is recorded from that execution log and from read-only observation of the live project (Management API: function list, `schema_migrations`, catalog queries). Where the two disagree this document says so.
* The security tab's only dispatcher changes are on branch `feat/dispatcher-v2` (unapplied, undeployed): see section 6.

## 1. Migrations applied live (per the execution log; confirmed present in `schema_migrations`)
| Version | Name | Applied (IST, from the log order) | Notes |
|---|---|---|---|
| `20261016300000` | `wa_dispatch_v2_schema` | step 2 of the log, before the function deploys; its backfill timestamp on `whatsapp_contacts` is 19:20:21 IST | Includes the `8932b97` revokes: `revoke all on whatsapp_contacts, whatsapp_wasi_templates from anon, authenticated` (+ `grant select` to authenticated), and `revoke all on whatsapp_event_templates from anon` (authenticated keeps write, gated by the ops-staff policy). Verified live now: anon has no privilege on any of the three tables; authenticated can SELECT contacts and the mirror only. |
| `20261016310000` | `wa_dispatch_v2_pending_normalisation` | step 4 of the log (after the deploys) | One BEFORE INSERT trigger `wa_outbox_pending_normalise`; inert while `settings.wa_dispatch_v2_enabled` is false. |

What 300000 did: `whatsapp_outbox` went from 19 to 28 columns (`wasi_message_id`, `delivery_status`, `delivered_at`, `read_at`, `failed_at`, `claimed_at`, `wasi_response`, `template_name`, `template_params`); status CHECK widened to `pending|sent|failed|received|skipped_no_template`; new tables `whatsapp_contacts`, `whatsapp_wasi_templates`, `whatsapp_event_templates`; function `wa_touch_contact` (service role only); `settings.wa_dispatch_v2_enabled boolean not null default false`; the 11-row "superseded" marking UPDATE (a no-op: those rows no longer exist).

**Discrepancy to be aware of:** the file `20261016300000_wa_dispatch_v2_schema.sql` on branch `feat/dispatcher-v2` is the pre-`8932b97` text (the revoke lines are missing there) because that branch cherry-picked `872b164`. The live schema has the revokes. The owner of `feat/dispatcher-v2` should take the file from `feat/dispatcher-fix` (`8932b97`) so the repository equals what was applied.

## 2. Functions deployed
Recorded in the execution log before the deploy (all `verify_jwt` unchanged, per `supabase/config.toml`):

| Function | Before | After (log) | verify_jwt |
|---|---|---|---|
| wasi-webhook | v43 (2026-10-06 11:20 UTC) | v44 | false |
| whatsapp-webhook | v50 (2026-10-06 11:20 UTC) | v51 | false |
| wa-dispatch-now | v11 (2026-10-06 11:19 UTC) | v12 | true |
| wa-milestone-dispatch | v13 (2026-10-06 11:19 UTC) | v14 | false |
| wa-scheduled-tasks | v22 (2026-10-06 11:19 UTC) | v23 | false |

**Observed live at ~19:35 IST (Management API):** wasi-webhook **v45**, whatsapp-webhook **v52**, wa-dispatch-now **v13**, wa-milestone-dispatch **v15**, wa-scheduled-tasks **v24**, all updated 2026-10-12 13:43-13:44 UTC (19:13-19:14 IST), `verify_jwt` as in the table. Each is one version above the "after" recorded in the log, so each function was deployed twice in that minute or the log's "after" numbers were recorded one deploy early. The code is the same `feat/dispatcher-fix` commit; confirm with whoever deployed.

**The code that is live is `feat/dispatcher-fix` at `8932b97`/`ab978e2`, NOT `feat/dispatcher-v2`.** It does not contain the alert job, the unknown-outcome network-error rule or the seeded mappings listed in section 6.

Secret: `WA_PUBLIC_APP_URL` is present on the project (name checked via the Management API; the log records it as `https://gv-mart.vercel.app`, which is not a secret). Other relevant secrets present: `WASI_API_BASE_URL`, `CRON_SECRET`, `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN`, `ALLOWED_ORIGINS`.

## 3. Rollback
Code (valid only while the flag is OFF, because `c88a8d2`'s `whatsapp.ts` has no v2 code), exactly as recorded in the log:
```
git worktree add ..\GV_mart_fn_rollback c88a8d2
cd ..\GV_mart_fn_rollback\gv-mart
$env:SUPABASE_ACCESS_TOKEN = "<PAT from gv-mart/.env>"
foreach ($f in "wasi-webhook","whatsapp-webhook","wa-dispatch-now","wa-milestone-dispatch","wa-scheduled-tasks") {
  npx supabase functions deploy $f --project-ref fsunrjithwcjtsutsgea --use-api
}
```
Run `supabase projects list` first (known account-alternation issue). Do not use `supabase functions download` into a working tree.

Database: leave the additive migrations in place (new columns are harmless). To neutralise the normaliser without a redeploy: flag OFF (the trigger is inert). To remove it: `drop trigger wa_outbox_pending_normalise on public.whatsapp_outbox;` (rollback file for 310000 is on `feat/dispatcher-fix`). Pre-change bundle bytes are not recoverable from Supabase after the overwrite; `c88a8d2` is the source of truth.

## 4. Row counts and baseline
| | Before (start of the log) | Now (observed ~19:40 IST) |
|---|---|---|
| `whatsapp_outbox` rows | 7 (4 inbound, 3 outbound `sent`) | 15 |
| of which `pending` / `skipped_no_template` | 0 / 0 | 0 / 0 |
| `whatsapp_outbox` columns | 19 | 28 |
| `whatsapp_contacts` rows | n/a | 1 (the test number) |
| `whatsapp_wasi_templates` (mirror) | n/a | 0 (template sync has not populated it) |
| `whatsapp_event_templates` (mappings) | n/a | 0 |
| orgs with `wa_dispatch_v2_enabled` / `wa_test_mode_enabled` | n/a | 0 / 0 |

Baseline (real organisation, the owner's two formulas): 64 leads, identity `7d8cf3fdda512f43119c39f0c386522a`, updated_at `3d0efc7afb9b124a09e52f11e4a51670`, identical before and after both migrations and the deploys (also re-read at 19:40 IST).

The 8 new outbox rows since 19:20 IST are the test number's bot conversation (menu, then the service journey up to `ask_address_confirm`, conversation still `active`). Nothing was created in the real organisation by it (no lead, customer, ticket, appointment, notification, task).

## 5. What the flag-ON step must check
Before `settings.wa_dispatch_v2_enabled` is set to true for the real organisation:
1. **Template mirror and mappings are empty.** Run the template sync (wa-scheduled-tasks does it; or a read-only `GET /api/v1/templates`) and confirm `whatsapp_wasi_templates` fills. Without mapping rows every system notification outside the 24 h window becomes `skipped_no_template`; that is intended but must be known. Seeds (`po.quote_request`, `test.hello`) are in `20261016320000` on `feat/dispatcher-v2`, NOT applied.
2. **`po_quote_request_doc_v3` exists twice on Wasi (en_US and en).** The send code refuses a duplicated name. The owner must delete one copy before supplier quote requests can go out as templates.
3. **Delivery receipts cannot be confirmed from the database today.** Replies sent on the legacy path (flag OFF, including every reply since the deploy) store Wasi's own id in `wa_message_id` (36 chars), so a `message.status` event can never match them. The Wasi webhook URL/secret settings have not been checked in Wasi's dashboard. After the flag is ON, send one approved-template message to the test number (owner approval each time) and confirm the row gets the WhatsApp id in `wa_message_id`, Wasi's id in `wasi_message_id`, and `delivery_status` moves `sent -> delivered`.
4. **Legacy writers still write `status='sent'` optimistically** (12 migrations, listed in the CI guard `src/lib/waOutboxSentGuard.test.ts` on `feat/dispatcher-v2`). With the flag ON the trigger turns `sent` into `pending` for the four dispatched ref types only (`service_ticket`, `service_visit`, `invoice`, `purchase_quote_request`). `purchase_order` rows are never dispatched (known gap) and stay `sent`.
5. **Test-mode gate (F-08)** must stay as is: `settings.wa_test_mode_enabled` OFF today. The gate runs after the row is inserted and claimed. With test mode ON and an empty allow-list EVERY send is blocked (fail closed); a settings read failure also blocks.
6. **No automatic reclaim.** A row stuck `pending`/claimed more than 15 minutes needs a human. The live code only lists claimed rows older than 10 minutes in Failed Sends; the 15-minute rule, the master notification and the daily skipped threshold exist only on `feat/dispatcher-v2` (migration `20261016320000`).
7. **Network errors**: live code treats any non-timeout exception as safe to retry (up to 3). The unknown-outcome rule on `feat/dispatcher-v2` is not deployed. Wasi has no idempotency key, so this can double-send on a connection reset after the request left.
8. **Templates to be approved first** (each `_en`; `_ta` after Tamil review): `gvm_service_booked`, `gvm_technician_assigned`, `gvm_technician_arrived`, `gvm_service_completed`, `gvm_invoice_issued`, `gvm_feedback_request`, `gvm_amc_expiring`. `appointment_reminder` is NOT an interim for "assigned". "On the way" has no emitter.
9. **Test-customer flag**: sends to the flagged test customer pass through the same dispatcher; keep every test send to that number, with an approved template, with the owner's approval each time.
10. **Pacing/cron**: `wa-milestone-dispatch` and `wa-scheduled-tasks` have `verify_jwt=false` and are guarded by `CRON_SECRET`; the GitHub Actions cron uses a repository secret (an earlier incident was a secret set under Environments). Confirm the next scheduled run is green after the flag flips.
11. **Real-organisation customers** are outside the 24 h window by default (`whatsapp_contacts` has one row). Free text to them is never sent; expect `skipped_no_template` rows until templates exist.
12. **Rollback with the flag ON**: flip the flag OFF first (30 s cache per warm instance), then redeploy from `c88a8d2` if needed.

## 6. What is on `feat/dispatcher-v2` (unapplied, undeployed), for the new owner
* `20261016320000_wa_dispatch_v2_alerts_and_mappings` (+ rollback, test): `settings.wa_skipped_alert_threshold` (default 10/IST day, 0 = off, master-editable on the Failed Sends tab) and the two seeded mappings. Passed 7/7 rolled back against the live schema.
* `wa-alerts.ts` + `runDispatchAlerts` in wa-scheduled-tasks: stuck-pending (>15 min) and skipped-per-day notifications to the master, once while unread.
* `wa-send-core.ts`: unknown-outcome network errors never resent; stuck threshold 15 minutes. `FailedSendsTab` and `automation.ts` match.
* `src/lib/waOutboxSentGuard.test.ts`: fails if a migration outside the frozen 12 inserts `'sent'` into `whatsapp_outbox`.
* Tests on that branch: `tsc` clean, 480 passed, 9 skipped.
* To fix there: restore the `8932b97` revoke lines into its copy of `20261016300000` (section 1).
