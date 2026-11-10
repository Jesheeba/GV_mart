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
- **Correction (2026-11-10, verified in code):** there is no `referred_by_user_id` column or `ReferrerPicker` component anywhere in the app — the earlier codebase survey was wrong on this point. The existing "referral" UI on `LeadDetailPanel.tsx` (`leads.detail.referralPoints`/`awardPoints`) is a manual, one-off "Award referral points" action: search for a customer via `Autocomplete`, give points, logged as a `referral_bonus` transaction — nothing is written back onto the lead row. So `referred_by_name`/`referred_by_phone` don't coexist with anything; they're simply new free-text fields on `leads`, independent of the points-award action.

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
