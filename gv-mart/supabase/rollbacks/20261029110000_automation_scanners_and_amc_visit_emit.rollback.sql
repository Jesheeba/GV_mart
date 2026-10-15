-- Rollback for 20261029110000_automation_scanners_and_amc_visit_emit.sql.
begin;
drop trigger if exists zz_automation_emit_amc_visit on public.appointments;
drop function if exists public._trg_automation_emit_amc_visit();
drop function if exists public.automation_scan_review(timestamptz, integer, integer);
drop function if exists public.automation_scan_feedback(timestamptz, integer, integer);
drop function if exists public.automation_scan_amc_expiring(timestamptz, integer[]);
drop function if exists public._automation_completed_tickets(timestamptz, integer, integer);
drop function if exists public._automation_ist_date(timestamptz);
update public.automation_events set has_emitter = false
 where event_key in ('amc.expiring', 'feedback.requested', 'review.google_requested', 'amc.visit_scheduled');
commit;
