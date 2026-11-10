# Feature: "Followed by" filter & per-person counts

## Purpose
Answer "which team member followed up with this lead" and "how many leads has each team member followed up with", using the real follow-up actor (`lead_activities.created_by`), not the lead's assignee.

## Architecture
- No migration — `lead_activities.created_by` already captures actor, `at` already captures timestamp (`gv-mart/src/types/database.ts` §2 of survey).
- New read path: a query/RPC returning, per org, `distinct count(lead_id)` grouped by `created_by`, for the "All team members" dropdown counts and for filtering the lead list to leads that have ≥1 activity by the selected actor.
  - Prefer a `select distinct lead_id, created_by from lead_activities where org_id = ... and created_by = $1` style query (existing RLS already scopes by org/staff) over a new RPC, unless row volume makes a server-side aggregate necessary — check row counts before deciding (Ponytail: don't build the heavier RPC path until the simple query is shown to be insufficient).
  - "Followed by" option list = distinct `created_by` values seen in `lead_activities` for the org, joined to `profiles` for display name (reuse whatever profile-name lookup `LeadTimeline.tsx` already uses to render actor names).
- UI: `LeadsPage.tsx` — add a new "Followed by" select, separate from the existing `assignedFilter`. Do not rename or repurpose `assignedFilter`; it remains the assignment filter.

## Impact map
- `LeadsPage.tsx` — new filter + new query; existing `assignedFilter` filter logic untouched.
- `LeadTimeline.tsx` — reuse its actor-name resolution logic rather than duplicating it.
- No writes, so no RLS/trigger risk; read-only addition.

## Edge cases
- Lead with zero activities → excluded from any "Followed by: X" filter result except "All team members".
- Actor who left the org / was deleted → still shows historical activities; display name resolution must handle a missing/deactivated profile gracefully (fallback label, not a crash).
- Count semantics: **distinct leads with ≥1 activity by that person**, not total activity rows — per spec §7.4, must not conflate the two.

## Acceptance criteria
- [ ] "Followed by" filter lists team members who have logged at least one follow-up activity, plus "All team members".
- [ ] Selecting a person filters the lead list to leads with ≥1 `lead_activities` row by that `created_by`.
- [ ] Per-person count (wherever surfaced — filter dropdown or a small stat) = distinct lead count, not activity-row count.
- [ ] Existing assignment filter continues to work unchanged and is not labeled "Followed by".
