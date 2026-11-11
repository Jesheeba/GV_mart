-- Regression fix (2026-11-11, applied live): 20261111100000_lead_referral_redesign.sql
-- used DROP FUNCTION + CREATE OR REPLACE to add the `when_needed` output column to
-- list_followups / list_leads_without_followup (required -- CREATE OR REPLACE alone can't
-- change a RETURNS TABLE(...) column list). DROP FUNCTION replaces the function object with
-- a fresh one that does NOT carry over prior GRANTs, so both RPCs silently lost `authenticated`'s
-- execute permission -- Daily Follow Up (My Day) stopped loading for every role, master included.
-- Confirmed live before this fix: has_function_privilege('authenticated', ..., 'execute') was
-- false for both, true for an untouched sibling (followup_counts). Restoring the same grant
-- every other RPC in this codebase carries.
grant execute on function public.list_followups(text, lead_status, text, text, boolean, text, uuid) to authenticated;
grant execute on function public.list_leads_without_followup(lead_status, text, text, text, uuid) to authenticated;
