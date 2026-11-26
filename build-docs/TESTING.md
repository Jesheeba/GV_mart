# TESTING — Leads Dashboard Enhancement

Test strategy per feature, mapped to each feature doc's acceptance criteria. Results filled in as each feature is implemented — none built yet.

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

## Live UI check — 2026-11-26 (owner signed in; Playwright drove the rest; option B = no sale created)
- Settings: "Prices include GST by default" shows, saves (DB true), and was switched back OFF afterwards (DB false).
- New Sale: switch starts on the default. ROP 2090 BLUE Included = ₹12,500 (GST ₹1,906.78); Extra = ₹14,750 (GST ₹2,250). + spare ₹750 Included → GST ₹114.41, grand ₹13,250. "Amount collected" follows: 13,250 ⇄ 15,635. The draft restores the GST choice.
- Search: "rop blue" finds ROP 2090 BLUE + ROP ROMA BLUE (space types normally, label once); "ros adapter 24v" finds exactly the 2 adapters with price/stock.
- New Quotation: Included ₹12,500 (GST ₹1,906.78) / Extra ₹14,750. Not saved.
- Found + fixed: the cart card subtitle still showed "RO (spreadsheet import) · 2090 BLUE" → now `productExtraParts` (tests 15/15), re-checked live.
- Not checked: the printed invoice (needs a real sale; owner chose B). Its maths is covered by the SQL test 19/19.
