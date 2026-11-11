# Feature: Referral details (freeform name + phone)

## Purpose
Capture "Referred by — name/phone" as plain text, for referrers who aren't necessarily an existing customer/profile in the system — separate from the existing bonus-points referral mechanism.

## Architecture
- Migration (additive, nullable):
```sql
alter table leads
  add column referred_by_name text,
  add column referred_by_phone text;
```
- **Correction history (2026-11-10):** this doc briefly claimed `referred_by_user_id` didn't exist anywhere, based on this worktree's local checkout — that was wrong. A live-DB query done before applying the migration found `leads.referred_by_user_id` (and `referral_type`) genuinely exist in production, added by another concurrent session not yet reflected in this branch (see build-docs/MEMORY.md, "Live-DB divergence found 2026-11-10"). The original plan decision — keep both the points-award flow and these new free-text fields, don't merge them — was correct. It doesn't change this feature's own columns: `referred_by_name`/`referred_by_phone` are new and additive regardless of what else is on `leads`. The visible UI on `LeadDetailPanel.tsx` (`leads.detail.referralPoints`/`awardPoints`) remains the separate, manual "Award referral points" action unrelated to these two columns.

## Impact map
- `NewLeadForm.tsx`, `LeadDetailPanel.tsx` — add two text inputs in a "Referral details" group, near existing `ReferrerPicker`/referral-points UI, visually separated so staff don't confuse the two referral concepts.
- No impact on `useAwardReferralPoints`, `referred_by_user_id`, or the referral-bonus schema (`20261202100000_referral_bonus_schema.sql`).

## Edge cases
- Phone format: store as entered (telephone input), no format enforcement beyond basic client-side pattern — matches rest of app's phone handling (check `mobile` field validation in `leadSchema` for the existing convention and mirror it).
- Both a picked referrer (`referred_by_user_id`) and freeform name/phone filled in simultaneously → allowed, not mutually exclusive; UI copy clarifies they can differ (e.g. staff referrer gets points, but customer explicitly also named a friend who told them).

## Acceptance criteria
- [ ] Referred-by name and phone text inputs exist on lead create/detail.
- [ ] Existing `ReferrerPicker`/bonus-points flow is unchanged.
- [ ] Both referral concepts are visually distinguishable in the UI (not merged into one ambiguous "referral" block).
