# TESTING — Leads Dashboard Enhancement

Test strategy per feature, mapped to each feature doc's acceptance criteria. Results filled in as each feature is implemented — none built yet.

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
- DONE (code) 2026-11-10, **migration NOT yet applied to the live DB** — per the standing rule "no DB write unless named in chat," `supabase/migrations/20261110100000_lead_detail_fields.sql` is written and committed as text only; waiting for the owner to explicitly say to apply it.
- `tsc --noEmit` clean. `validateLeadDocument` unit-tested (`leadDocuments.test.ts`, 4 tests, all pass): accepts allowed type/size, rejects disallowed MIME, rejects over-size, accepts exactly-at-limit.
- Correction caught before applying: the first draft of this feature's design doc omitted "When do they need it?" (in the original requirements) — added `when_needed` to the migration, types, schema, form, and detail card before anything went live.
- Not yet tested (needs the live DB): check constraint rejecting negative budget/invalid tds_status at the DB layer, RPC `record_lead_document` end-to-end, storage policies. Will run once the migration is applied.

## referral-details
- Planned: both `referred_by_user_id` and freeform name/phone can be set independently without one clobbering the other.

## followup-workspace-reminders
- Planned: saving "Today's conversation" produces exactly one `lead_activities` row; setting next-follow-up updates `leads.next_followup_at`; enabling a reminder creates one `tasks` row with correct `ref_type`/`ref_id`/`due_at`; rescheduling doesn't orphan a stale task.

## Regression sweep (run after any feature lands)
- Existing assignment filter (`assignedFilter`) on `LeadsPage.tsx`.
- Existing stage-change buttons, quotation creation, referral-points award flow on `LeadDetailPanel.tsx`.
- Existing `MyDayPage.tsx` follow-up worklist (overdue/today/upcoming/none tabs).
