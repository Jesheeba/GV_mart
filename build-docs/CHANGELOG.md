# CHANGELOG — Leads Dashboard Enhancement

## lead-category-chips (2026-11-10)
- Removed "All topics" filter and the hidden "Lead type" select from `LeadsPage.tsx`.
- Added a visible category chip bar (All leads / Service / Product / Spare / AMC) bound to the existing `kind` filter — no new column, reuses `leads.kind`/`kind_key`.
- Extracted chip ordering into `leadCategoryChips.ts` + unit tests.
- Removed now-unused `leads.filters.allTopics` i18n key (en/ta); reworded `allKinds` to "All leads".
- Branch: `feat/lead-dashboard-enhancement`, worktree `_local_only/worktrees/lead-dashboard`.

## lead-summary-tiles (2026-11-10)
- Replaced the 4-tile KPI block (Total/Won/Lost/Conversion rate) with 6 tiles: Total, New, Contacted, Quotation, Won, Lost — each shows count + percentage.
- Percentage formula changed to count/total*100 for every tile (previously Won%/Lost% were % of closed leads only); Total shows 100% when leads exist, 0% when none.
- Extracted to pure `leadSummaryTiles.ts` + unit tests; `conversionRate` i18n key and its only usage removed as dead code.

## followed-by-filter (2026-11-10)
- Added a new "Followed by" dropdown on the Leads list, separate from the existing assignment filter — filters by who actually logged a follow-up activity (`lead_activities.created_by`), not who the lead is assigned to.
- New read-only service/hook `listLeadFollowupActors`/`useLeadFollowupActors`; grouping/dedup logic extracted to `followedByFilter.ts` + unit tests (count = distinct leads, never activity-row count).
- No migration, no write path, no change to the existing assignment filter.

## lead-detail-fields (2026-11-10) — LIVE
- New columns on `leads`: `customer_requirement`, `special_description`, `user_source`, `budget`, `when_needed`, `tds_status`, `report_storage_path`; new `lead-reports` storage bucket + `record_lead_document` RPC.
- Caught and fixed before going live: original draft missed "When do they need it?" — added as `when_needed` across migration/types/schema/form/detail card.
- `NewLeadForm.tsx` gets the new optional create-time fields; `LeadDetailPage.tsx` gets a new `LeadDetailFieldsCard` (view/edit the fields + upload/view the document).
- Hand-patched `database.ts` (Docker/`gen types` unavailable in this environment).
- **Applied 2026-11-10 on owner's "GO APPLY"**, via direct `pg` connection (no psql in this environment), one transaction per migration file, versions registered in `supabase_migrations.schema_migrations`. Pre-apply check found the live DB had diverged from this branch (other sessions' migrations up to `20261204190000` not in this branch's history) — checked for collisions before applying; found none. Post-apply verified columns/bucket/function exist via direct query.

## referral-details (2026-11-10) — LIVE
- New columns on `leads`: `referred_by_name`, `referred_by_phone`.
- `NewLeadForm.tsx` and `LeadDetailFieldsCard.tsx` get the two new inputs, grouped as "Referral details."
- **Correction to an earlier correction:** this plan's original decision ("keep both the points-award flow and new freeform fields, don't merge") was right. A mid-build claim that `referred_by_user_id` didn't exist was based on this worktree's stale local checkout — the live-DB check before applying found it (and `referral_type`) genuinely do exist, added by another session. Doesn't change anything about this feature's own columns, which are independent and additive either way.
- Applied in the same run as lead-detail-fields above.

## followup-workspace-reminders (2026-11-10) — no migration needed
- "Today's conversation": relabeled the existing single-line "Add note" into a multiline textarea on the same `add_lead_note` RPC path — no new write path.
- "Next follow-up date/time": unchanged, already the existing `SetFollowupDialog`/`set_lead_followup` RPC.
- "Reminder": new selector in `SetFollowupDialog` (at / 15 min / 1 hour / 1 day before) creates a `tasks` row via the extended `createTask`/`CreateTaskInput` (now exposes `dueAt`/`refType`/`refId`/`description`, which already existed on the table).
- Known gap: reminders are not yet wired into `RescheduleDialog`, and there's no dedup if a lead is rescheduled after a reminder task already exists — documented, not solved in this pass.

## lead-referral-redesign (2026-11-11)
- TDS: dropdown -> free text input (3-preset check constraint dropped).
- Removed duplicate "User source / referred through" field from lead create/detail.
- when_needed surfaced on My Day (list_followups) and no-followup (list_leads_without_followup) cards.
- Referred-by redesigned: Technician/Staff picker, existing-customer search (prefills name/phone), or free-text, shown only for referral/customer_app sources.
- Migration (20261111100000_lead_referral_redesign.sql) APPLIED live 2026-11-11 (owner GO APPLY) — see entry below.
- Verified (not changed): referral-points award on conversion is still manual only, not automatic — see feature doc.

## lead-referral-redesign migration applied live (2026-11-11)
- 20261111100000_lead_referral_redesign.sql applied live on owner's "GO APPLY": tds_status check constraint dropped, reporting_staff source seeded (all orgs), list_followups/list_leads_without_followup redefined with when_needed. Fixed in-flight: CREATE OR REPLACE can't add an output column to a RETURNS TABLE function -- needed DROP FUNCTION first for both RPCs (committed fix matches what ran). Verified live: free-text TDS insert succeeds, reporting_staff rows present, both RPCs expose when_needed.

## regression fix: list_followups/list_leads_without_followup grants (2026-11-11)
- The DROP FUNCTION + CREATE OR REPLACE used earlier today to add when_needed silently dropped authenticated's execute grant on both RPCs (new function object, old GRANTs not carried over) -- broke Daily Follow Up for every role, reported as "not loading in master". Fixed live: granted execute back to authenticated on both. New migration 20261111110000_fix_list_followups_grants.sql records it.

## lead-unified-interaction-log (2026-11-11) — no migration needed
- Merged `LogOutcomeSheet.tsx` + `RescheduleDialog.tsx` + the inline "Add note" toggle on `LeadDetailPage.tsx` into one new `LogInteractionSheet.tsx` with a 3-way mode switch (Reached customer / Couldn't reach · push it / Just a note). Deleted the two old files — no lingering dead code.
- `LeadDetailPage.tsx`: one "Log interaction" button (+ a "Reschedule" quick button when a follow-up is already set) replaces the old three separate buttons/toggle.
- `MyDayPage.tsx` / `FollowupCard.tsx`: the two per-row quick-action buttons ("Log interaction", "Reschedule") now open the same merged sheet via one `onLogInteraction(item, mode)` callback instead of two separate dialogs/write paths.
- `CallReturnPrompt.tsx` (auto-opens after a staff member returns to the app post-call) repointed at the merged sheet, defaulted to Mode A with `defaultChannel="call"` — this entry point was missed in the first design-doc draft and fixed before building.
- No new RPC: all three modes call the pre-existing `log_lead_outcome` / `reschedule_followup` / `add_lead_note` RPCs exactly as before; `reschedule_followup`'s already-existing but previously-unused `note` parameter is now actually passed, so a reschedule's conversation note is captured instead of silently dropped.
- Added a stuck-threshold warning (Mode B only — reschedule's postpone rule is unambiguous; outcome-mode has no client-visible field to base a correct warning on, so none is shown there rather than guessing).
- New i18n keys: `leads.interaction.title`, `leads.interaction.mode.{outcome,reschedule,note}`, `leads.interaction.stuckWarning` (en + ta).

## lead-unified-interaction-log: drop the separate quick Reschedule button (2026-11-12)
- `LeadDetailPage.tsx` and `FollowupCard.tsx` (My Day) each had two buttons — "Log interaction" and a quick "Reschedule" — both opening the same merged sheet. Per owner request, collapsed to one "Log interaction" button everywhere; reschedule is now reached only via the mode switch inside the sheet.
- `LeadDetailPage.tsx`: removed `interactionMode` state and the `openInteraction(mode)` helper; the button and the `reopen` path both just call `setInteractionOpen(true)` and let the sheet default to "outcome". The "Set follow-up" button (for leads with no follow-up yet, a different RPC/dialog) is unchanged.
- `FollowupCard.tsx`: `onLogInteraction` prop dropped its `mode` argument; `MyDayPage.tsx` simplified to match (`onLogInteraction={setInteractionFor}`, no `interactionMode` state).
- Removed the now-orphaned i18n keys `leads.followup.logOutcome` and `leads.followup.reschedule` (en + ta) — nothing references them after the button merge; `leads.interaction.title` and the in-sheet mode labels replace them.
