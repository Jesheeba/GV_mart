# Feature: Lead referral/source redesign (2026-11-11)

## Purpose
Four owner-reported gaps in the lead form that shipped with lead-detail-fields
(04eb108) / referral-details (a44979e): TDS locked to 3 presets instead of a
free reading, a free-text "User source" duplicating the Source dropdown,
"When do they need it?" not surfacing anywhere staff actually work follow-ups,
and "Referred by" not adapting to who's doing the referring.

## Changes
- `tds_status`: dropdown → free text input. DB check constraint
  (`leads_tds_status_check`) dropped; column stays `text`.
- `user_source` ("User source / referred through"): removed from
  NewLeadForm.tsx and LeadDetailFieldsCard.tsx — duplicated the Source select
  immediately above it. Column left in place, unused (no data loss, no
  migration risk).
- `when_needed`: now also returned by `list_followups` and
  `list_leads_without_followup` (additive output column, live bodies pinned
  before editing) and shown on FollowupCard/NoFollowupCard — the customer's
  stated urgency is visible exactly where staff schedule/work follow-ups.
- Referred-by: new `ReferredBySection.tsx`, shared by NewLeadForm and
  LeadDetailFieldsCard. Shown only when source is `referral`/`customer_app`
  (or the lead already has referral data). Three modes:
  - Technician/Staff → existing `ReferrerPicker` (`referred_by_user_id`,
    bonus-eligible, NewLeadForm only — not editable after creation).
  - Existing customer → `Autocomplete` search over `customers`, on pick
    prefills `referred_by_name`/`referred_by_phone` (no new column).
  - Someone else → the existing free-text name/phone inputs.
  - `customer_app` defaults to "Existing customer" (an app lead is by
    construction from an existing customer).

## Explicitly NOT done (flagged, not silently built)
- Automatic referral-points award on lead→customer conversion. Verified:
  `move_lead_to_customer`/`_lead_apply_status` only carry over
  `referred_by_user_id` attribution (package 3); crediting a customer's
  `referral_points` ledger is still only the manual "Award referral points"
  button in LeadDetailPanel (defaults to 50, staff-entered, post-conversion).
  Making this automatic is a money-adjacent policy decision — left for the
  owner to decide, not assumed.

## Migration (written, NOT yet applied live)
`supabase/migrations/20261111100000_lead_referral_redesign.sql` — drops the
tds_status check constraint, redefines `list_followups` and
`list_leads_without_followup` with one additive `when_needed` column each.
Blocked from applying it myself this session (harness production-deploy
guard); needs the owner to run it (Supabase SQL editor, or re-authorize).
Until applied: typing a non-preset TDS value will fail to save, and
when_needed won't show on My Day cards yet.

## Impact map
- `NewLeadForm.tsx`, `LeadDetailFieldsCard.tsx`, `FollowupCard.tsx`,
  `NoFollowupCard.tsx`, `ReferredBySection.tsx` (new).
- `lib/validation/automation.ts` (tdsStatus free text, userSource removed).
- `types/database.ts` (list_followups/list_leads_without_followup Returns).
- No change to `move_lead_to_customer`, `_lead_apply_status`, or the
  referral_bonus_rates/events schema.
