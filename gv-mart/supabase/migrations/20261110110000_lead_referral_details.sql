-- Lead Dashboard Enhancement, feature 5 (referral-details) —
-- build-docs/features/referral-details.md. Additive, nullable columns.
--
-- Verified in code before writing this (earlier codebase survey was wrong):
-- there is no referred_by_user_id column or ReferrerPicker component
-- anywhere in the app. The existing "referral" UI on LeadDetailPanel.tsx is
-- a manual "Award referral points" action (search a customer, give points)
-- — nothing is persisted on the lead row. So these two columns don't
-- coexist with or replace anything; they're simply new free-text fields.

alter table public.leads
  add column referred_by_name text,
  add column referred_by_phone text;
