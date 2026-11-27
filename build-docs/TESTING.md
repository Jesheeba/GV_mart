# TESTING — Leads Dashboard Enhancement

## no-gst-bill (2026-11-26)
- SQL rehearsal (migration + `supabase/tests/no_gst_bill.test.sql`, rolled back): 21/21. Covers AC1 every RPC with GST 0, AC2 old call shapes unchanged, AC3 monthly rent bill, AC4 quotation flag, AC5 ACLs/defaults/columns/existing rows. A no-trace check afterwards: nothing left behind.
- Rollback rehearsal: all 8 functions return to their live md5 + ACL.
- `src/lib/noGstBill.test.ts` 15/15: totals, default never none, old-draft restore, 3-option toggle, "GST not charged" summary, and the no-GST flag sent on every path (sale, quotation, AMC, rental, both offline jobs).
- `tsc -b` clean.
- Full vitest: 1405 passed, 26 failed. The same 5 files (OTA, WA dispatch, waOutboxSentGuard) fail identically on unchanged main in this worktree, so the failures are environmental.
- Not browser-checked.

## build fix: leadCustomerEmbed.test.ts (2026-11-26)
- `tsc -b` (npm run build) failed on main: the test used node:fs/__dirname, and src is not typed for Node. Switched it to Vite `import.meta.glob(?raw)` like waOutboxSentGuard.test.ts.
- Added a check that the glob finds more than 100 files. Mutation check: a planted un-hinted `customers(...)` embed failed the test; after removing it, 3/3 pass.
- `npm run build` exit 0. Full vitest: 1395 passed, 2 failed. Both failures also fail on main.

## gst-everywhere (2026-11-26)
- `src/lib/gstEverywhere.test.ts` (E1-E5): 10/10. Numbers match the SQL test so the screen total equals the server invoice.
- `tsc -p tsconfig.app.json` clean. Full vitest: 1392 passed, 2 failed. Both failures (waOutboxSentGuard, wa-event-context) also fail on main.
- Migration APPLIED LIVE 2026-11-26 (owner "go apply") after the 8 baseline md5s matched. One overload each; ACLs as before (anon none).
- `supabase/tests/gst_everywhere.test.sql`: **20/20**, run alone, rolled back, row counts identical before and after.
  - Fixture fix 1: a technician can hold only one open untimed appointment, so visit 2 got a second technician.
  - Fixture fix 2: month 1 and the cron bill share created_at in one transaction, so the test now selects the cron bill by payment_method null.

## missing-i18n-keys (2026-11-26)
- `keysComplete.test.ts` (AC1, AC2): 6/6 pass. Against origin/main's JSON, 5/6 fail (missing en, missing ta, en dups, ta dups, budget key), so the guard catches the original bugs.
- `parity.test.ts` (AC3): passes with the allowlist removed. All src/lib/i18n tests: 72/72.
- `tsc -p tsconfig.app.json` clean. Full vitest: 1383 passed, 2 failed. Both failures (waOutboxSentGuard, wa-event-context) also fail on main.

## onsite-payment-method (2026-11-26)
- `technician.test.ts`: UPI accepted, missing method rejected (path "method"), transfer without reference rejected. The old "rejects an invalid method value" test used "upi" as its invalid example, which was wrong because UPI is an offered method; it now uses "cheque".
- `tsc -b` clean, `vite build` OK, vitest serial 1212 passed / 2 failed (same pre-existing waOutboxSentGuard, wa-event-context). i18n parity OK.
- NOT browser-checked: reaching the on-site invoice step needs a technician arrival + open visit, which would write real data.

Test strategy per feature, mapped to each feature doc's acceptance criteria. Results filled in as each feature is implemented — none built yet.

## referral-sources R3+R4 (screens + points switch) — 2026-11-26
- `src/lib/referrer.test.ts` 22/22 (+8): wrapper args per kind (technician keeps plain RPC = AC5), incomplete referrer sends nothing, points toggle needs amount > 0, amount 0..100000 whole number, en/ta strings.
- `tsc -b` clean, oxlint clean (no new warnings), `vite build` OK.
- Full vitest in a clean worktree with the R3 diff applied: 1231 passed / 2 failed (pre-existing waOutboxSentGuard, wa-event-context; same 2 on origin/main).
- Found: inside the feature worktree (dev server running there) the full run also fails 24 OTA tests; they pass alone, with `--no-cache` for subsets, and in any clean worktree with identical code. Environment-only, not caused by this change; not chased further.
- Not browser-checked by me: signing in uses the live auth host. Owner checks in the local tab.
- Merge into main (2026-11-26): full vitest with `--no-cache` twice = 1377 passed / 2 failed (same pre-existing pair as main). Root cause of the extra OTA / wa-milestone failures seen earlier: worktrees share one node_modules via junction, so vitest's transform cache served another branch's compiled code (a test failed on `abortSignal`, which isn't in this tree). Use `--no-cache` in junctioned worktrees.

## referral-sources R2 (migration, NOT applied) — 2026-11-26
- `supabase/tests/referral_sources.test.sql` via rolled-back rehearsal (begin + migration + test, ends in RAISE): **40/40 pass** on the first run. Covers AC-1/5/6/7/8/9, guards, first-referrer-wins, history rule, atomic rollback of a failed sale, carry-over, points toggle/once/paid-later, delete of referrer, grants, billing RPC md5 unchanged.
- Leak check afterwards (read-only): 0 new columns/functions, 0 test orgs/users, carry-over md5 still 9a4e65a1.
- Rollback exercise (migration + rollback, ends in RAISE): 0 cols / 0 fns / 0 triggers left, carry-over md5 back to 9a4e65a1, no anon/authenticated EXECUTE.

## referral-sources R1 (picker + quick-add) — 2026-11-26
- `src/lib/referrer.test.ts` 14/14: AC1/AC2 kinds (no walk-in/lead), kind switch clears fields, completeness, AC3 quick-add schema (name/mobile/optional area, invalid mobiles), AC4 existing-customer match, en/ta key parity.
- Regression: `tsc -b` clean, oxlint clean, full vitest 1223 passed / 2 failed. The 2 failures (waOutboxSentGuard, wa-event-context) also fail on clean origin/main c83a0a3, so they were there before this change.
- Not browser-checked: signing in uses the live auth host. Owner to check New Lead → Source Referral / Customer app → Add new customer.
## choice-dropdowns-not-set — 2026-11-26
- New test files (all pass):
  - `choiceNotSet.{money,service,leads,admin}.test.ts`: 13 / 17 / 18 / 18 tests.
  - `services/addressChoiceNotSet.test.ts`: 5.
  - `i18n/choiceNotSetKeys.test.ts`: 58 keys in en+ta.
  - `ChoiceSelect.test.ts`: 8.
- Each test is named for its acceptance criterion: nothing pre-selected; Not set blocks required fields; Not set saves empty for optional ones; edit keeps the saved value; outcome pre-fill kept; segment rule incomplete until every part is set; tier Not set → `tier_id` null.
- Changed tests:
  - `choiceNoPreselect.test.ts`: the 3 address "must choose" tests were rewritten for the owner's reversed rule.
  - `crudForm.test.ts`: test name only.
  - Owner-reversed rules only; none were weakened.
- DB rehearsal `address_choice_not_set` (rolled back): 12/0.
- Full suite: 1320 pass. tsc clean. Build OK.
  - The same 26 environment failures as plain main in this worktree (ota, WA dispatcher, outbox guard, event context).
- Not automated (no DOM test env): start values that are component state only (task priority, staff role, availability, bike, adjustments, attribute/relation/doc type, phrase category). Covered by code review.

- `src/components/shared/ChoiceSelect.test.ts` (8): required placeholder disabled + nothing pre-selected; optional "Not set"; saved value selected on edit; null/undefined value; label/id link for focus; error alert + aria; NO_SPINNER classes. All pass.
- Built CSS contains the spinner-hiding rules. tsc clean, vite build OK.
- Full suite: 1193 pass. The 26 failures (ota, WhatsApp dispatcher, outbox guard, event context) are identical on plain main in the same worktree with this change stashed: environment issue, not this change.

## UX pass (choice-no-preselect, input-density, date-display) — 2026-11-26
- Unit tests added: `choiceNoPreselect.test.ts`, `crudForm.test.ts` (AC1-6), `fieldWidth.test.ts` (AC1), `formatDate.test.ts` (AC2-4: year rule, IST midnight across 3 TZs, null, range, invoice date).
- Integrated branch (all 3 merged + header fix): `tsc -b` clean, `vite build` OK, vitest serial 1145 passed / 2 failed (same pre-existing waOutboxSentGuard, wa-event-context).
- Browser (local dev, view only, nothing saved): per-feature checks by each builder (screens in scratchpad choice/, density/, dates/; about 750 date strings measured, 0 wrapped; overflow check passed on every density page at 390 and 1280). Integrated smoke: 16 admin pages at 1280, 8 at 390, 5 technician pages at 390 — 0 crashes, 0 console errors, 0 horizontal overflow.
- Not browser-checked: customer-app screens (no customer test login), on-site visit payment (needs an open job), New Sale payment step / Record payment (would need real data).

## pin-autocorrect
- 2026-11-26. vitest: `arrivalMode` (8 cases: AC1/4/5 + boundary) and `pinStatus` (6 cases), outbox contract, i18n parity all pass. Full serial suite 1098 passed / 2 failed (same pre-existing waOutboxSentGuard, wa-event-context).
- `tsc`: clean apart from the pre-existing unused `fullAddress` in CustomerFormPage.tsx (from origin/main, untouched).
- `supabase/tests/pin_autocorrect.test.sql` run LIVE once after apply, one DO block ending in RAISE: ALL PASSED (AC1 move+event+notification, no task; AC2 next arrival locks; AC3 locked untouched; AC4 inside/too far/120m/null accuracy no-op; AC5 no-pin set; AC6 other technician not_assigned, master rejected; AC7 anon no EXECUTE). Checked afterwards: 0 corrected events, 0 pin_autocorrected notifications, settings unchanged (2000/250).
- NOT browser-verified: Chrome extension not connected and the `.env.test` master login was rejected on local dev.

## arrival-location-lock
- 2026-11-26. `supabase/tests/arrival_location_lock.test.sql` run LIVE after apply, inside one DO block ending in RAISE (fully rolled back; verified afterwards: 0 events, 0 locked, no test rows, fixture pin/ticket unchanged). Result: ALL PASSED - AC1 lock+event (distance 50-60m), AC2 no second move, AC3 secondary locked with is_primary untouched and no new rows, AC4 out-of-radius / 120m accuracy not locked, AC5 direct lat/lng and verified_at changes rejected (master and postgres), AC6 text edit keeps pin, AC7 opadmin + blank reason rejected / master reset keeps pin + logs reason, AC8 other technician no-op + non-technician rejected, insert can't be pre-verified.
- AC9 (post-apply read): anon has no EXECUTE on arrival/reset RPCs; authenticated can't insert events or execute the guard fn.
- `tsc` clean. vitest serial run (`--no-file-parallelism`): 2 failed / 1084 passed = identical to main baseline (pre-existing: waOutboxSentGuard, wa-event-context). Parallel full run in this worktree shows 24 extra mock failures in otaManager + customer-link-otp tests that pass in isolation and in serial - environment flake, not this change.
- NOT browser-verified: no address is locked live yet, and creating one would be a real DB write.
## customer-form-map-search-prefill
- 2026-11-25. `tsc --noEmit` clean. No automated test: vitest runs in plain Node with no DOM/RTL harness.
- Manual browser check on local dev server (master test account, nothing saved), all pass:
  - Typing Door/Street/PIN fills the map search box ("3/353, 10th Street, 620019, Trichy, Tamil Nadu"); no dropdown pops up on its own.
  - Focusing the pre-filled box shows matching Google suggestions.
  - Picking a suggestion fills blank Main Area/Zone AND stays "Location pinned / Location confirmed" (failed before the fix: showed "Exact location not pinned").
  - Editing Landmark after pinning clears the pin and updates the box text (existing stale-pin safety kept).
- Not checked: edit-mode customer with an existing pin; AddressForm/AddressPinDialog callers (logic change there is only "no re-search after selecting").

## lead-category-chips
- DONE 2026-11-10. Chip order/active-filter logic extracted to a pure function (`leadCategoryChips.ts`) and unit-tested (`leadCategoryChips.test.ts`, 4 tests, all pass): fixed Service→Product→Spare→AMC order regardless of input order, drops inactive categories, empty-list case, ignores unknown keys. `tsc --noEmit` clean. No RTL component tests — this codebase has no `@testing-library/react` dependency; pure-logic extraction follows the existing `kpiTilesView.ts` convention instead.
- Not separately tested (manual-only, no test harness for this): visual active/pressed state, "All topics" filter removed from DOM, "Lead type" select removed from DOM — verified by code reading, not an automated test.

## lead-summary-tiles
- DONE 2026-11-10. Count+% logic extracted to pure `leadSummaryTiles.ts` (`computeLeadSummaryTiles`), unit-tested (`leadSummaryTiles.test.ts`, 4 tests, all pass): zero-leads case (all 0%, Total 0%), mixed-status counts/percentages, rounding, fixed tile order (total/new/contacted/quoted/won/lost). `tsc --noEmit` clean.
- Behavior change (per spec, documented in PLAN.md): Won%/Lost% now read "of total leads" (count/total*100), replacing the previous "of closed leads" denominator the 4-tile block used. Conversion-rate tile removed (not in the new 6-tile spec); no other code referenced it.
- Not separately tested: visual tile layout/responsive grid — manual-only, no RTL harness in this repo.

## followed-by-filter
- DONE 2026-11-10. `groupLeadIdsByActor`/`distinctLeadCountByActor` extracted to pure `followedByFilter.ts`, unit-tested (`followedByFilter.test.ts`, 4 tests, all pass) — including the exact dedup case the spec calls out: an actor logging 5 activity rows on the same lead counts as 1 distinct lead, not 5. `tsc --noEmit` clean.
- New read path `listLeadFollowupActors`/`useLeadFollowupActors` (org-wide `lead_id, created_by` from `lead_activities`, RLS-scoped) feeds the filter dropdown and the list predicate — no writes, no migration.
- Not separately tested: dropdown name resolution for a deactivated/missing profile (falls back to "Unknown user" label) — covered by existing i18n key, not a dedicated test; manual verification only.

## lead-detail-fields
- DONE 2026-11-10, **migration APPLIED LIVE** (owner said "GO APPLY"). `supabase/migrations/20261110100000_lead_detail_fields.sql` ran against the production DB directly via `pg` (psql unavailable in this environment), each migration in its own transaction, then registered in `supabase_migrations.schema_migrations`.
- Pre-apply check (not skipped): queried the live schema first and found it had diverged from this worktree's local checkout — other sessions had applied migrations up to `20261204190000` that aren't in this branch's `supabase/migrations/` history, and `leads` already had `referred_by_user_id`/`referral_type` columns this worktree's `database.ts` didn't know about. Confirmed no name collisions with the new columns/bucket/function before applying.
- Post-apply verification (read-only): `leads` has all 7 new columns with correct type/nullability; `lead-reports` bucket exists (private, 10 MB limit); `record_lead_document` function exists. All confirmed via direct query, not assumed.
- `tsc --noEmit` clean. `validateLeadDocument` unit-tested (`leadDocuments.test.ts`, 4 tests, all pass).
- Correction caught before applying: the first draft of this feature's design doc omitted "When do they need it?" — added `when_needed` to the migration, types, schema, form, and detail card before anything went live.
- Not yet tested: a full authenticated end-to-end RPC call (`record_lead_document`) from the running app — only the function's existence and the schema were verified directly against the DB; a real upload through the UI hasn't been exercised.

## referral-details
- DONE 2026-11-10, **migration APPLIED LIVE** alongside lead-detail-fields (same apply run, same transaction-per-file approach).
- **Correction to my own earlier correction:** I'd said "no `referred_by_user_id` exists" based on this worktree's local checkout, and built this feature on that basis. The live-DB check done before applying (see lead-detail-fields above) found `referred_by_user_id` AND `referral_type` genuinely DO exist live — added by another session's migration not yet in this branch. The ORIGINAL plan decision ("keep both mechanisms, don't merge") was right all along; my in-between "simpler than planned" claim was wrong, though harmless — `referred_by_name`/`referred_by_phone` are new, independent, additive columns regardless of what else exists on `leads`, so nothing had to change in the actual migration or code.
- `tsc --noEmit` clean; full leads test suite re-run (20/20 pass) as a regression check.

## followup-workspace-reminders
- DONE 2026-11-10. No migration needed — `tasks.ref_type`/`ref_id`/`due_at`/`description` already existed on the table, just not exposed by `CreateTaskInput`; extended it (additive optional params, all existing call sites unaffected).
- "Today's conversation": relabeled the existing single-line "Add note" action/i18n keys into a multiline textarea — converged on the one existing `add_lead_note` RPC path rather than adding a second way to write `lead_activities`, per the feature doc's explicit "no duplicate code path" requirement.
- "Next follow-up date/time": unchanged — already flows through the existing `SetFollowupDialog`/`set_lead_followup` RPC; no new write path added.
- "Reminder": added a selector to `SetFollowupDialog` only (not Reschedule — see gap below). `reminderDueAt` offset math extracted to pure `followupReminder.ts`, unit-tested (`followupReminder.test.ts`, 4 tests, all pass): at/15m/1h/1d offsets computed correctly from the chosen follow-up datetime.
- `tsc --noEmit` clean; full leads test suite re-run (20/20 pass) as regression check.
- **Known gap, documented not silently skipped:** reminder creation is only wired into the first-time "Set follow-up" dialog. `RescheduleDialog` does not yet create/update a reminder task, and there is no dedup/cancel-existing-task logic if a lead is rescheduled after a reminder was already created — flagged in the feature doc's edge cases as needing its own design pass, not solved here under this plan's scope.

## lead-unified-interaction-log
- DONE 2026-11-11. No migration, no new RPC — pure client-side consolidation of `LogOutcomeSheet.tsx` + `RescheduleDialog.tsx` + the inline "Add note" toggle into one `LogInteractionSheet.tsx`, reusing `log_lead_outcome`/`reschedule_followup`/`add_lead_note` exactly as before (verified by reading `useLeadFollowups.ts`: all three mutation hooks already invalidate the same `["followups"]`/`["leads"]` query keys, so the "lead moves accordingly" requirement held without new invalidation code).
- `CallReturnPrompt.tsx` (the auto-open-after-call prompt) repointed at the merged sheet, defaulted to Mode A ("outcome") with `defaultChannel="call"` — this was missed in the first draft of the design doc and caught before implementing (see feature doc's impact map).
- `FollowupCard.tsx` keeps two quick-action buttons ("Log interaction" / "Reschedule") for one-tap speed from the My Day list, but both now open the same merged sheet via one `onLogInteraction(item, mode)` callback — not two separate write paths.
- Stuck-threshold warning implemented only for Mode B (reschedule): the rule is documented and unambiguous (`reschedule_followup` always bumps `postpone_count` when pushed later). Deliberately NOT implemented for Mode A (outcome) — there is no client-visible field on `lead_outcomes` distinguishing which outcomes count as a postpone server-side, and a guessed warning risks being wrong, which is worse than showing none.
- `tsc --noEmit` clean. `oxlint` clean on all 5 changed/added files. No RTL component-test harness exists in this repo (consistent with every other feature in this plan) — verified by code reading: grepped for remaining `LogOutcomeSheet`/`RescheduleDialog`/`OutcomeSheetLead` references before deleting the two old files (none found outside themselves).
- Full leads-related pure-logic regression suite re-run (`lead-edit`, `lead-followups`, `lead-lists`, `lead-outcome-followup`, `lead-spread`, `leadReferrers`, `call-return`): 52/52 pass, unchanged — none of those files were modified, confirming no logic regression in the reused helpers.
- Not yet tested: a real device walkthrough of all three modes + the call-return auto-open + the stuck warning threshold in the running app (manual-only, no RTL harness in this repo, consistent with every other feature above).

## Regression sweep (run after any feature lands)
- Existing assignment filter (`assignedFilter`) on `LeadsPage.tsx`.
- Existing stage-change buttons, quotation creation, referral-points award flow on `LeadDetailPanel.tsx`.
- Existing `MyDayPage.tsx` follow-up worklist (overdue/today/upcoming/none tabs).

## sidebar-pinned-items (2026-11-25)
- `src/app/admin/nav.test.ts` › "sidebar-pinned-items": 6 tests (per-user key, corrupt storage, dedupe/order, pin order, unknown+Dashboard dropped, role-hidden key hidden) — PASS.
- `tsc -b` clean. Full suite: 1084 pass, 2 fail — `waOutboxSentGuard.test.ts`, `wa-event-context.test.ts`: pre-existing on main, unrelated (don't import changed files).
- Not covered by automated tests (no DOM test env): pin button render/hover, collapsed view — manual check needed.

## vendor-flow-fixes (2026-11-25)
- `src/lib/purchase.test.ts` › "vendor-flow-fixes": 19 tests (AC3/4/7/8/10/11) — PASS.
- `tsc -b` clean. Full suite: 1103 pass, 2 fail — `waOutboxSentGuard.test.ts` (offender `20261204220000_wire_gvm_templates_phase_b_new_triggers.sql`, already failing on main) and `wa-event-context.test.ts`, both identical on a clean origin/main run.
- `supabase/tests/vendor_flow_fixes.test.sql`: 43 checks AC1–AC12 + grants. NOT RUN — needs the migration applied first (new enum value), and DB writes need owner's named approval. Runs in its own transaction, ends in `raise exception 'RESULTS…'`.
- Migration, rollback, test SQL: parsed with libpg-query (Postgres 17 parser): all statements OK; 13/13 non-trigger PL/pgSQL bodies OK; 3 trigger bodies hit a parser-library JSON bug that live, known-valid trigger functions hit identically.
- Bug found while testing: first draft of `_queue_supplier_whatsapp` always wrote `'sent'` (guard test caught it); now `pending` under v2 dispatch, `sent` only when v2 is off (live: off).
- Not covered automatically (no DOM test env): the UI flows — manual check needed after apply.
## picker-search (F1) — 2026-11-26
- `src/lib/productSearch.test.ts`: 13/13 pass (A1 multi-word spare search, A2 multi-word product search, A3/A4 labels, A5 spaces/case edge cases).
- Regression: full suite 1097 pass / 2 fail / 17 skipped. The 2 failures (`waOutboxSentGuard.test.ts`, `wa-event-context.test.ts`) are WhatsApp tests that import none of the changed files; they were already failing on origin/main feaaa84.
- `tsc --noEmit`: only the pre-existing `CustomerFormPage.tsx` unused `fullAddress` error (already failing on origin/main, has its own fix branch).
- Not browser-verified: signing in would send the test login to the live Supabase auth host. Owner to try New Sale → Spare tab.

## quick-add F3a: complaint name — 2026-11-26
- `src/lib/quickAdd.test.ts`: 6/6 pass (offer only new names, dedupe case/space-insensitive, blank, 120-char limit).
- `supabase/tests/quick_add_complaint_type.test.sql`: **11/11 PASS on live, 2026-11-26**, run alone (not concatenated) after apply. Before/after counts identical (test orgs 0, complaint_types 71, test users 0, profiles 14), so nothing persisted. It covers ACL (no anon/PUBLIC), ops add, dedupe, cross-org isolation, sales/tech rejected, blank/long/null-category, RLS unchanged. It ends in RAISE RESULTS, so it is safe to run as migration+test in one request after GO APPLY.
- Regression: full suite 1103 pass / 2 fail. The failures are the same 2 WhatsApp tests that were already failing on origin/main.
- Migration applied live 2026-11-26 on owner's "go apply". ACL verified: anon no, authenticated yes, no PUBLIC grant.

## gst-inclusive-toggle F2 — 2026-11-26
- `src/lib/gstInclusive.test.ts`: 12/12 pass (AC numbers 11,800→1,800; 12,500→1,906.78; discount then GST; Extra unchanged; rate 0; 100% discount; payable follows the switch; redemption floor). Existing `sale-calc.test.ts` still green.
- `supabase/tests/gst_inclusive_toggle.test.sql`: **19/19 PASS on live, 2026-11-26**, run alone after apply. Three earlier runs stopped on test-fixture mistakes (new-org 5% discount cap, products need brand+model, `rental_plans.monthly_rate` is generated); only the fixtures were fixed. Before/after row counts were identical on all 4 runs, so nothing persisted. It covers ACLs, one overload each, all 6 functions on `_gst_amount`, SQL math = JS math, create_sale included/extra/org-default/partial payment, create_quotation explicit/default/legacy NULL, and run_rental_billing on the org default.
- Full suite 1114 pass / 2 fail (the same WhatsApp tests that were already failing on origin/main); tsc clean apart from the CustomerFormPage error that was already there.

## customer-water-household + water-solution-followup (2026-11-26)
- `src/lib/validation/customer.test.ts`: 18 pass (hardness, problems cap/length, health removed, cleanHouseholdProblems).
- `src/app/admin/customers/waterHouseholdForm.test.ts`: WH-1 prefill round-trip, patch mapping, empty-patch detection, dirty rule, FU date rules (follow-up + postpone), schema limits. All pass.
- `src/services/customerWaterHousehold.test.ts`: exact writes and order (profile before RPC), no address/health writes, when the RPC is or isn't called, error surfacing, moved-out filter (admin + customer app). All pass.
- Subtotal for those 3 files: 42/42 pass. Full suite: 1110 pass, 2 fail. The 2 failures (`waOutboxSentGuard`, `wa-event-context`) also fail on clean origin/main (verified in a temp worktree), so they are unrelated. `tsc` clean, `vite build` ok.
- DB: `supabase/tests/customer_water_household_v2.{fixtures,test}.sql`, about 70 checks (backfill mapping, real-org untouched, checks, guard, RPC security incl. cross-org/anon, unique index, postpone/convert/clear, reminder idempotency, cron). Rehearsal file is `_local_only/rehearsal-files/2026-11-26_customer_water_household_v2.rehearsal.sql` and passes the guard check. Run 2026-11-26, see below.
- Live read-only precheck (2026-11-26): every object to drop exists, nothing else depends on them; 2 address rows hold water data, 1 health row, tech flag off in all orgs.

## customer-data-sync (2026-11-26)
- `address.test.ts`: 20 pass. The old "area alone is structured / full_address is stale" test was replaced (it encoded the bug), and resolveFullAddress plus round-trip tests were added.
- `customerWaterHousehold.test.ts`: added the single-write updateMember test. Moved-out filter is covered for admin + customer app.
- PostgREST filter paths (`member_count.moved_out_at`, `customers.customer_members.moved_out_at`) were checked against live with the anon key. They parse (reach RLS), and a bogus path is rejected with PGRST108.
- DB: about 20 SYNC/ADDR checks were added to `customer_water_household_v2.test.sql` (90 checks total). **Not run yet.**
- Full suite: 1118 pass, the same 2 pre-existing failures as main. `tsc` clean, `vite build` ok.
- Manual only (no DOM test env): draft restore of complaint type/referrer, lead fields card Cancel/Edit.
- **DB rehearsal run 2026-11-26 (rolled back): 90 pass / 0 fail.** Harness fixes on the way: (1) granted EXECUTE on the pg_temp helpers, since this project revokes default EXECUTE; (2) one test sent an email with spaces, which the existing customer_members_email_format check rejects (the app trims first); (3) the real-org check now names the changed columns. The only live non-water change is 1 blank profession filled (intended, from 20261216120000).
- **Final rehearsal on merged/renumbered migrations: 90/0.** Apply-file dry run (rolled back) passed all checks. **Applied live 2026-11-26** in one DO block; post-check: 3 versions registered, 3 customers columns present, address water columns and health table gone, cron `water-followup-due` active, RPCs not executable by anon, 2 customers carry backfilled water/problems. 10 pre-existing primary member/customer name-or-mobile mismatches left as-is (see customer-data-sync.md).

## Live UI check — 2026-11-26 (owner signed in; Playwright drove the rest; option B = no sale created)
- Settings: "Prices include GST by default" shows, saves (DB true), and was switched back OFF afterwards (DB false).
- New Sale: switch starts on the default. ROP 2090 BLUE Included = ₹12,500 (GST ₹1,906.78); Extra = ₹14,750 (GST ₹2,250). + spare ₹750 Included → GST ₹114.41, grand ₹13,250. "Amount collected" follows: 13,250 ⇄ 15,635. The draft restores the GST choice.
- Search: "rop blue" finds ROP 2090 BLUE + ROP ROMA BLUE (space types normally, label once); "ros adapter 24v" finds exactly the 2 adapters with price/stock.
- New Quotation: Included ₹12,500 (GST ₹1,906.78) / Extra ₹14,750. Not saved.
- Found + fixed: the cart card subtitle still showed "RO (spreadsheet import) · 2090 BLUE" → now `productExtraParts` (tests 15/15), re-checked live.
- Not checked: the printed invoice (needs a real sale; owner chose B). Its maths is covered by the SQL test 19/19.

## quick-add F3b — 2026-11-26
- `src/lib/quickAdd.test.ts` (findByLabel added) + `src/lib/leadOptionKey.test.ts`: 13/13 pass. The key rule cases mirror the SQL test.
- `supabase/tests/quick_add_lead_option.test.sql`: written, NOT RUN (migration not applied). It covers ACL, sales add, dedupe, kind/product_type tables, archived not re-enabled, cross-org, ops/tech refused, unknown list, blank/long/symbol-only label, RLS unchanged.
- **Migration applied live 2026-11-26** ("go apply"). ACL: anon no, authenticated yes. SQL test **13/13 PASS**, run alone; before/after counts identical.
- **Live UI check** (owner signed in, Playwright):
  - New Lead shows 3 "Add new" links. Existing names typed in other case/spacing select the existing option with no insert: Source "whatsapp" → WhatsApp, Product type "ro / WATER purifier" → RO / Water Purifier, Kind " SERVICE " → Service.
  - Supplier on Create PO ("pvm" → PVM) and Bill Entry ("CHENNAI electro traders") selected the existing supplier, count unchanged.
  - Edit Lead entry point is hidden on main (1761eaa, update_lead_details not live), so its quick-add is dormant.
- **Test-script mistake:** my automation clicked the Source link three times. That created 2 unused lead sources in the owner's org ("ro / WATER purifier" key ro_water_purifier, "service" key service; 0 leads use them). Left in place pending the owner's decision. This was a test-script error, not a code bug: the feature did what it was told.

## fix(referral-sources): leads<->customers embed ambiguity (2026-11-26)
- Bug: after 20261228100000, leads has 2 FKs to customers -> PostgREST PGRST201 on `leads?select=*,customers(...)` (leads list + lead detail broke in prod). Reproduced against live API (HTTP 300 PGRST201).
- Fix: `customers!leads_customer_id_fkey(...)` in services/automation.ts listLeads/getLead; new FKs added to types/database.ts Relationships.
- Test: src/lib/leadCustomerEmbed.test.ts (2/2) — scans src + supabase/functions for un-hinted leads<->customers embeds; verified it FAILS on the old code. Live API with the hinted select: 200.
- tsc clean. Full suite: only the dispatcher-mock `abortSignal` failures (pre-existing on main since 05707bd, unrelated files) + known wa-event-context.
- Customer detail page ("Couldn't load customers") NOT reproduced: getCustomer works via API and under owner RLS simulation; awaiting browser error details.

## fix(vendor-flow): live apply + merge (2026-11-26)
- SQL: supabase/tests/vendor_flow_fixes.test.sql 43/43 PASS on live (own transaction, ends in RAISE, residue check 0).
- Unit: purchase.test.ts + i18n keysComplete pass after fixing a duplicate purchase.errors block from the merge (main had added its own; pricePositive moved into it).
- leadCustomerEmbed.test.ts rewritten to import.meta.glob (the node:fs version failed tsc -p tsconfig.app.json on main); still fails when the hint is removed.
- tsc clean, vite build OK. Full suite: only pre-existing OTA + WA dispatcher-mock (abortSignal) + waOutboxSentGuard(20261204220000) + wa-event-context failures.

## feat(rework) (2026-11-26) — built, DB NOT applied
- Unit: `src/lib/rework.test.ts` 13/13 — AC1 window (inside/edge/outside/master-raised/invalid), AC5 penalty P2 (unset, ≤X, X+1, X+3, X=0), AC4/AC5 on-site choice, UI completion time.
- Guard: `testCustomerGuard.test.ts` failed until `report_rework_summary` + `technician_rework_count` were added to `must_exclude` (both exclude test customers) — guard working as designed.
- i18n: 29 keys inserted as text into the LAST occurrence of each object in en+ta (files had duplicate keys; parse-and-rewrite would drop content). Diff is insert-only; keysComplete/parity tests pass.
- tsc -b clean; oxlint 0 errors (no warnings in rework files).
- Full suite: only the known pre-existing failures (waOutboxSentGuard, wa-event-context, plus order-dependent OTA + WA dispatcher-mock files that pass in isolation on this branch).
- SQL (written, NOT run — no DB write without the owner naming it):
  - `supabase/tests/rework_core.test.sql` — AC1–AC9: roles, reason, window + master-raised window, linked ticket, responsible tech, auto-assign, inactive tech → unassigned + notification, both auto-pickers skip rework, reassign keeps responsible, guard triggers, cancel clears needs_revisit + re-mark, free = ₹0 even if app claims chargeable, spare/charge ⇒ paid with stock deducted, escalation rules (responsible only, ≥10 chars, free only, once, RLS blocks pre-approved insert, ops cannot decide, master can, technician notified), counts, report, grants, real-data fingerprint.
  - `supabase/tests/rework_penalty_salary.test.sql` — X/Y unset, X=2/3/4/0 with 4 reworks, paid + test-customer + other-month excluded, master omit/undo/add on rework and late deductions, ops blocked, recharge rules unchanged, floor + shortfall, grants, real salaries untouched. Synthetic org, LAST month only.
- Generators: `_local_only/rehearsal-files/rework/gen_rework_core.py` takes the LATEST definition of each re-issued function (found the gst_everywhere body after rebase); `gen_rework_penalty.py` refuses if compute_salary was redefined after 20261118100000.
- 2026-11-26 live: pre-check found 20270101100000 taken by no_gst_bill + 13-arg create_service_invoice → renumbered to 20270102*, regenerated from live bodies (27bf86e).
- `20270102100000_rework_enums` APPLIED live (owner choice "apply enums + test core"); enum values + version row verified read-only.
- Core rehearsal 1 (begin; migration + test; RAISE): 57/58 — FAIL "AC2 assigned to the original technician" = test fixture (window check's rework held tech1's 09:00 slot → technicianBusy, correct behaviour). Fixed in 156e0d5. Residue check: nothing persisted.
- Core rehearsal 2: 58/58 PASS. `20270102100100_rework_core` APPLIED live (owner: "re-test, apply if all pass"); in-request checks + independent read-only post-check clean (1 invoice overload, no anon EXECUTE, 0 test residue, compute_salary md5 unchanged).
- `20270102100200_rework_penalty_salary` NOT applied (payroll: needs typed APPROVED after its own rehearsal).

## quotation-edit-discount (2026-11-27)
- Vitest: `src/lib/quotationDiscount.test.ts` (AC4 cap/reason/negative, ₹→% for the sale step) 7/7. Related suites (quotations, sales, i18n parity/keys, services) 277 pass / 17 skipped. tsc clean, oxlint clean, `npm run build` OK.
- SQL `supabase/tests/quotation_edit_discount.test.sql`, 21 checks. 2026-11-27, owner chose "apply DB first, then merge":
  - Precheck (read-only): live create_sale / create_quotation / _sale_create_line_invoice identical to the repo bodies.
  - Rehearsal 1 (migration + test, rolled back by RAISE) FAILED: `leads_owner_id_fkey`. leads.owner_id references technicians, not staff. Fix: owner_id dropped; lead assigned to the creator via assign_lead (best-effort) + new test check.
  - Rehearsal 2: **21/21 PASS**. Leak check: nothing persisted.
  - APPLIED live as one guarded DO block (md5 guards, version row, grants/columns/triggers checks, existing quotation + invoice fingerprints unchanged): APPLY_OK. Post-check matches.
- Not covered by automation: the Edit popup UI and sale prefill (no DOM test env). Check by hand after apply.

## exact-rupee-discount (2026-11-27)
- Vitest: `saleDiscountPercent` (₹2000 on ₹31000 → bill discount exactly 2000, product+spare split adds up, cap edge, junk input) + floored quotation cap (333.35 → 33.33). Related suites pass. The only failures are pre-existing and unrelated: waOutboxSentGuard (flags old 20261204220000) and otaManager (fails standalone too). tsc clean, build OK.
- SQL `supabase/tests/exact_rupee_discount.test.sql` 7 checks. Precheck: live create_sale md5 552c6566… matched. Rehearsal 1: 5/5. It surfaced the quotation cap round-up edge, fixed with trunc. Rehearsal 2: **7/7 PASS**. Leak check clean.
- APPLIED live (guarded DO block, APPLY_OK). New create_sale md5 6df514a55841a52b99337f6689f84d7e.

## spare-stock-limits (2026-11-27)
- Vitest `src/lib/stockLimits.test.ts` 5 cases (none / set / one missing / non-whole / max < min). i18n parity + keys + crudForm 88 pass. tsc clean, build OK. No DB change (inventory RLS inventory_write_ops already allows master). Not hand-checked in the browser.
