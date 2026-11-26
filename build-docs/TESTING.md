# TESTING — Leads Dashboard Enhancement

Test strategy per feature, mapped to each feature doc's acceptance criteria. Results filled in as each feature is implemented — none built yet.

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
