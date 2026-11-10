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

## lead-detail-fields (2026-11-10) — code committed, migration NOT yet applied live
- New columns (migration text only, not yet run): `customer_requirement`, `special_description`, `user_source`, `budget`, `when_needed`, `tds_status`, `report_storage_path` on `leads`; new `lead-reports` storage bucket + `record_lead_document` RPC.
- Caught and fixed before going live: original draft missed "When do they need it?" — added as `when_needed` across migration/types/schema/form/detail card.
- `NewLeadForm.tsx` gets the new optional create-time fields; `LeadDetailPage.tsx` gets a new `LeadDetailFieldsCard` (view/edit the fields + upload/view the document).
- Hand-patched `database.ts` (Docker/`gen types` unavailable in this environment).
- **Waiting on explicit "apply this migration" from the owner before running it against the live DB**, per the standing no-DB-write-unless-named rule.
