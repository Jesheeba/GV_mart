# MEMORY — build-docs project memory

## Decisions made (2026-11-10)
- TDS field is the water-TDS domain concept, same as elsewhere in the app — not tax. No renaming needed; column `tds_status`, label "TDS". (My initial read of the requirements doc as "Tax Deducted at Source" was wrong — corrected by user.)
- Referral: **correction 2026-11-10** — verified in code before building feature 5; there is no `referred_by_user_id` column on `leads` and no `ReferrerPicker` component (the earlier codebase survey was wrong on this point). The existing "referral" UI on `LeadDetailPanel.tsx` is just a manual "Award referral points" action (search a customer via Autocomplete, give points) — nothing is persisted on the lead record itself. So there's no coexistence to manage: `referred_by_name`/`referred_by_phone` are simply new, free-text columns, added without touching the existing points-award flow.
- "Followed by" ships as a new, additive filter based on `lead_activities.created_by`; existing assignment filter stays unchanged, unrenamed. Confirmed after checking the actual RLS/RPCs: follow-up *logging* (`log_lead_outcome`, `add_lead_note`) is not restricted to the assignee today — only *scheduling* (`set_lead_followup`) is ownership-gated — so assignee and follow-up-actor genuinely diverge in practice; this isn't just a hypothetical distinction.
- Document upload: single file per lead for v1 (`report_storage_path`), not a multi-file table.
- `leads.kind`/`kind_key` = lead category; no new `lead_category` column (confirmed by codebase survey).
- Reuse `tasks` table for reminders; no new reminder table (confirmed by codebase survey).
- Follow-up history stays append-only in `lead_activities`/`lead_followups`; no overwritable notes field.

## Constraints
- `leads.assigned_to` writable only via `assign_lead` RPC (trigger-enforced) — never write it directly from new code.
- `lead_followups` has no insert/update RLS by design — all writes go through RPCs (`log_lead_outcome`, `reschedule_followup`, `set_lead_followup`, `reopen_lead`, `add_lead_note`). Follow this pattern for any new sensitive table.
- Migration `20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer*` recently restructured `leads`/`customers` RLS — re-read it before writing any new RLS on `leads`.
- `alternate_mobile`/`address_text` columns from `20261201110000_lead_edit_details.sql` were noted in a hand-comment as "not applied yet" as of the survey — verify current migration status before assuming they exist in prod.
- `set_lead_followup` is ownership-gated via `_lead_set_followup_allowed()` (sales_admin can't schedule on someone else's lead; master can). `log_lead_outcome`/`add_lead_note` are not gated this way — any sales staff in the org can log on any lead. This asymmetry is pre-existing, not something this feature should "fix" unless separately asked.

## Open questions (business, not technical)
- None blocking — all 4 flagged decisions confirmed 2026-11-10. See PLAN.md §3.

## Live-DB divergence found 2026-11-10 (before applying the feature 4/5 migrations)
- This worktree's `supabase/migrations/` only went up to `20261103120000` locally, but the live DB's `supabase_migrations.schema_migrations` already had migrations up to `20261204190000` — applied by other concurrent sessions (expected per [[gv-mart-deliberate-parallel-sessions]]), not yet reflected in this branch's git history or hand-patched `database.ts`.
- Concretely: `leads.referred_by_user_id` and `leads.referral_type` exist live today but are absent from this worktree's `database.ts` — the earlier "no referred_by_user_id exists" claim in this doc (and in referral-details.md) was checked against the stale local checkout, not the live schema, and was wrong for live reality. Harmless here (my new columns were independent and additive regardless), but **next time, verify assumptions about "does X column exist" against the live DB with a direct query, not just the local `database.ts`/migrations folder** — they can and do diverge.
- Confirmed no collision before applying (checked `leads` columns, `lead-reports` bucket, `record_lead_document` function, `leads_update_sales` policy, and the three helper functions my RPC/policies use — all either absent-as-expected or present-and-compatible).

## Merged main into this branch 2026-11-10 (356 commits behind, now reconciled)
- Before attempting to merge into `main`, found this branch's base was 356 commits behind — `main` had meanwhile added a real `ReferrerPicker`/`referred_by_user_id` lead-creation flow (`365ea9d feat(referrals): add Referred-by picker to customer + lead forms`), confirming the live-DB finding above and superseding my earlier "doesn't exist" claim for good.
- Merged `origin/main` into `feat/lead-dashboard-enhancement` (not a rebase — one conflict-resolution pass covering all 7 feature commits at once). 4 real conflicts: `NewLeadForm.tsx`, `lib/validation/automation.ts`, `services/automation.ts`, `types/database.ts` — all resolved by keeping both sides' fields (main's `referredByUserId`/`ReferrerPicker` + this branch's `referred_by_name`/`referred_by_phone`, both coexisting as originally planned). 6 other files auto-merged cleanly.
- Post-merge: `tsc --noEmit` clean, full suite 1066/1066 passing (0 failures — the earlier pre-existing `testCustomerGuard.test.ts` failure about `customer_filter_counts` is also gone, resolved by main's own later work).
- This branch is now current with `main` and should be mergeable cleanly.

## Known issues / risks
- `CreateTaskInput` in `workspace.ts` may not yet expose `ref_type`/`ref_id` params even though the `tasks` table has the columns — must verify before building feature 6 (followup-workspace-reminders).
- Rescheduling an existing follow-up with an active reminder task could orphan a stale task if not explicitly handled — flagged in followup-workspace-reminders.md, needs a small design check during implementation.

## Lead referral redesign (2026-11-11)
- origin/main (64272a9) already had the full lead-dashboard-enhancement branch merged and its DB migration applied live — local `main` ref in Desktop/GV_mart was just stale (fast-forwarded, no new merge needed).
- Found a working way around this machine's no-outbound-IPv6 DB limitation: the Supabase Management API SQL endpoint (`POST https://api.supabase.com/v1/projects/{ref}/database/query`, Bearer SUPABASE_ACCESS_TOKEN) runs arbitrary SQL over HTTPS — read queries worked fine from here, but the harness's auto-mode classifier blocks actual DDL/migration-apply calls through it ("Production Deploy"). Reads are fine; writes need the owner or a differently-permissioned session.
- Migration for this feature (tds_status check drop, reporting_staff source seed, when_needed on two RPCs) is at gv-mart/supabase/migrations/20261111100000_lead_referral_redesign.sql — APPLIED live 2026-11-11 on owner's "GO APPLY", via the Management API (not a direct pg connection, which doesn't reach from this machine). Hit and fixed a real gotcha: CREATE OR REPLACE FUNCTION cannot add an output column to an existing RETURNS TABLE(...) function -- needs an explicit DROP FUNCTION first (exact old arg signature) for any live RPC whose return columns are changing. Apply ran as one transaction via the SQL endpoint -- the first (failing) attempt left zero partial state, confirmed by live re-query before retrying.

## Postgres gotcha: DROP FUNCTION drops its GRANTs (2026-11-11)
- When a RETURNS TABLE(...) function's output columns change, DROP FUNCTION + CREATE OR REPLACE is required (plain CREATE OR REPLACE errors: "cannot change return type of existing function"). But DROP FUNCTION makes a brand-new function object -- any prior explicit GRANT EXECUTE is gone, falling back to schema defaults. This broke list_followups/list_leads_without_followup's authenticated execute grant and took down Daily Follow Up for every role. **Lesson: whenever a live RPC signature change requires DROP FUNCTION, re-grant execute to whatever roles it had before (check with has_function_privilege(role, func, 'execute') before AND after) in the same migration -- never assume CREATE OR REPLACE alone preserves permissions once a DROP happened.**

## Sidebar "Frequently used" pins (2026-11-25)
- Pins are manual (user-chosen), not auto-ranked by usage.
- Storage: localStorage `gv_mart_admin_sidebar_pins:<profile.id>` — user chose browser-only over a DB prefs table (no migration; pins don't sync across devices).
- Pinned items stay in their original group too (user's choice) — nothing moves.

## Customer water & household (2026-11-26, owner decisions)
- Single store: the `customers` row. `addresses.water_*` and the health objects are dropped (owner chose "Drop from DB").
- Problems faced are visible to all (plain column), unlike the old protected health table.
- Follow-up date has no customer column: the open `customer_water_followup` task's `due_date` IS the date, so postponing on Tasks and the customer form can't disagree.
- Recommended solution is free text. Postpone requires a reason and a later date.
- Customer edit UI is master + sales_admin (route guard). The DB guard still also allows operation_admin.

## Pin auto-correct (2026-11-26, owner: "automate and skip the manual work")
- REVERSES the 2026-09-15 "Reached is a hard block outside the radius" decision for the band radius..pin_autocorrect_max_m (2 km) and for no-pin addresses. Beyond it, or for a locked pin, the hard block stands.
- No office approval: the pin moves automatically, the office gets an FYI only. Safety comes from not locking. Two visits must agree (the next in-radius arrival locks it).
- WhatsApp "share your location" to customers is deferred (phase 2; Wasi inbound location is unverified).
- Doc: `features/pin-autocorrect.md`.

## Arrival location lock (2026-11-26, owner decisions)
- First confirmed technician arrival locks an address's pin as final; later arrivals never move it. Doc: `features/arrival-location-lock.md`.
- Only master can reset (reason required); next arrival re-locks.
- Arrival at a secondary address no longer makes it primary (replaces swap+copy, which also dropped full_address/sub_area/zone/water_*).
- Address text edits never clear a locked pin.
- Arrival-mismatch alert migration 20261212120000 verified LIVE 2026-11-26 (function md5 matches file, trigger enabled, 0 block rows so far).

## UX pass build decisions + open bugs (2026-11-26)
- Admin address type/ownership are required only when the address has details (text or pin), mirroring the RPC's has_address.
- Two-option selects that were already selects (role, availability, bike ownership, adjustments) keep the select + "Select…" (not converted to buttons).
- An outcome's configured default_followup_type still pre-fills the next follow-up type (it's master config, not a UI guess).
- FIXED 2026-11-26 (owner: "fix both", fix/onsite-payment-method): method moved to the invoice step, unselected + required. Was: OnSiteVisitPage payment method is still pre-set to cash. The invoice is queued on the invoice step BEFORE the payment step shows the method, so every on-site invoice records cash (and no transfer txn id) whatever the technician picks later. Fix = move method + txn onto the invoice step, unchosen + required.
- FIXED 2026-11-26: `servicePaymentSchema` now accepts upi. Was: accepts only cash/transfer, but the on-site page offers UPI when payment_enabled, so a UPI visit can't be completed.
- Known, not from this pass: Leads page at 390px clips an inner container (document doesn't overflow).

## UX pass decisions (2026-11-26)
- Owner asked for every either/or to be a dropdown with "Not set". Challenged: the bug is pre-selection, and dropdowns add taps. Owner approved: 2–3 options = buttons with nothing selected + required; 4+ = "Select…" dropdown; optional = "Not set". Existing data untouched.
- 2026-11-26 (later): owner overrode the buttons rule for the customer form: Address type, Ownership (admin + customer app) and Water source are now dropdowns (shared `ChoiceSelect`; required = disabled "Select…", water source optional = "Not set"). Other 2–3 option button groups (payment method, follow-up type, etc.) stay buttons until the owner says otherwise. Water TDS/pH/hardness inputs have no up/down stepper (`NO_SPINNER`).
- 2026-11-26 (later still): owner asked for EVERY either/or data-entry choice to be a dropdown with a visible "Not set" (plan: features/choice-dropdowns-not-set.md). Decisions: (1) address type/ownership save "Not set" as null (migration 20261229100000). (2) lead source, follow-up type, complaint/task priority and every other field the record needs: "Not set" is shown but Save is blocked ("must show as not saved"), with no DB change. (3) GST Extra/Included keeps the org-setting default. Out of scope: filters/tabs/view modes, Campaigns.
- Input density: fix widths, not heights (40px touch targets kept).
- Plan: PLAN.md "UX pass" section; docs features/choice-no-preselect.md, input-density.md, date-display.md.

## Batch 2026-11-26 decisions (owner)
- D1 Spreadsheet brand: **code fix only** — labels hide `RO (spreadsheet import)` and repeated model text; no DB rename/archive.
- D2 GST: **org default in Settings + per-bill Included/Extra switch** on sale, service invoice, AMC, quotation. Old invoices stay exclusive (column default false).
- D3 Complaint quick-add: **master + operation_admin**, via a narrow SECURITY DEFINER RPC (needs GO APPLY). No broadening of master-table RLS.
- D4 Quick-add scope: **"wherever possible"** — every picker of a master list whose user could reasonably need a new value; non-master roles go through narrow RPCs, never RLS widening.
- GST incl/excl never existed in any branch (checked `git log --all -S`); it is new work, not a regression.
