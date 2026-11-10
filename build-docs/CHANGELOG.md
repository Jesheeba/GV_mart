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
