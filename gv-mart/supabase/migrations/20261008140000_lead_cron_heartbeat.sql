-- Lead follow-up Phase 2, gap 5: dead-man's switch for the pg_cron job
-- 'lead-followup-notifications'.
--
-- pg_cron cannot alert on its own death, so the job records a heartbeat in the
-- EXISTING cron_job_heartbeats table on every tick (success or failure). The
-- three GitHub-Actions-driven Edge Functions already call checkAndAlertStaleJobs()
-- on every invocation; once 'lead_followup_notifications' is added to its
-- EXPECTED_INTERVAL_MINUTES map (5 minutes, stale after 15), any of those
-- functions firing will notice this job going quiet and raise the existing
-- 'cron_job_stale' in-app notification to master.
--
-- Safe to apply before the Edge Functions are redeployed: until then the new
-- heartbeat row is simply never read.

create or replace function public.lead_followup_cron_tick(p_job_key text default 'lead_followup_notifications')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.run_lead_followup_notifications();
  exception when others then
    -- the failed run's own writes are rolled back by the exception block;
    -- record WHY it failed so the alert can say so
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;

  -- a healthy run also clears any stale-alert cooldown, so the next outage alerts again
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;

revoke execute on function public.lead_followup_cron_tick(text) from public, anon, authenticated;

-- First heartbeat now, so the checker does not report "never recorded a completed run"
-- in the window between this migration and the first scheduled tick.
insert into public.cron_job_heartbeats (job_key, last_run_at, last_status)
values ('lead_followup_notifications', clock_timestamp(), 'ok')
on conflict (job_key) do nothing;

-- Point the existing job at the wrapper (same name, same schedule).
select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'lead-followup-notifications'),
  command := 'select public.lead_followup_cron_tick()'
);
