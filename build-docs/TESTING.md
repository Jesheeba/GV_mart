# TESTING — Leads Dashboard Enhancement

Test strategy per feature, mapped to each feature doc's acceptance criteria. Results filled in as each feature is implemented — none built yet.

## lead-category-chips
- DONE 2026-11-10. Chip order/active-filter logic extracted to a pure function (`leadCategoryChips.ts`) and unit-tested (`leadCategoryChips.test.ts`, 4 tests, all pass): fixed Service→Product→Spare→AMC order regardless of input order, drops inactive categories, empty-list case, ignores unknown keys. `tsc --noEmit` clean. No RTL component tests — this codebase has no `@testing-library/react` dependency; pure-logic extraction follows the existing `kpiTilesView.ts` convention instead.
- Not separately tested (manual-only, no test harness for this): visual active/pressed state, "All topics" filter removed from DOM, "Lead type" select removed from DOM — verified by code reading, not an automated test.

## lead-summary-tiles
- Planned: unit test on the tile-computation function with fixture lead lists (0 leads, mixed statuses, all-one-status) asserting count+% per tile incl. zero-total 0% rule.

## followed-by-filter
- Planned: query returns distinct-lead-per-actor counts (not activity-row counts) against a fixture `lead_activities` set with a repeat-actor-same-lead case to verify dedup.

## lead-detail-fields
- Planned: DB check constraint rejects negative budget and invalid `tax_tds_status`; RPC upload rejects disallowed MIME/oversized file; form round-trips all fields on an existing lead.

## referral-details
- Planned: both `referred_by_user_id` and freeform name/phone can be set independently without one clobbering the other.

## followup-workspace-reminders
- Planned: saving "Today's conversation" produces exactly one `lead_activities` row; setting next-follow-up updates `leads.next_followup_at`; enabling a reminder creates one `tasks` row with correct `ref_type`/`ref_id`/`due_at`; rescheduling doesn't orphan a stale task.

## Regression sweep (run after any feature lands)
- Existing assignment filter (`assignedFilter`) on `LeadsPage.tsx`.
- Existing stage-change buttons, quotation creation, referral-points award flow on `LeadDetailPanel.tsx`.
- Existing `MyDayPage.tsx` follow-up worklist (overdue/today/upcoming/none tabs).
