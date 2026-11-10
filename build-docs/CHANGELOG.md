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
