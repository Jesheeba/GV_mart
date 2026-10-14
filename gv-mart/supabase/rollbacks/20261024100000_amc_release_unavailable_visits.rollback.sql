-- Rollback for 20261024100000_amc_release_unavailable_visits.sql.
-- Restores amc_assign_cron_tick() to the body from 20261022100000 (assign only, no release step) and drops the release function,
-- the unavailability helper and the two triggers. Visits already released stay released (open / unassigned or re-assigned);
-- withdrawal notifications and audit rows already written are not removed (audit_log is append-only).
begin;

drop trigger if exists zz_amc_release_on_leave on public.technician_availability;
drop trigger if exists zz_amc_release_on_inactive on public.technicians;
drop function if exists public._trg_amc_release_on_leave();
drop function if exists public._trg_amc_release_on_technician_inactive();

create or replace function public.amc_assign_cron_tick(p_job_key text default 'amc_assign_due_visits')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.assign_due_amc_visits();
  exception when others then
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;
revoke all on function public.amc_assign_cron_tick(text) from public, anon, authenticated;
grant execute on function public.amc_assign_cron_tick(text) to service_role;

drop function if exists public.release_unavailable_amc_visits(timestamptz, uuid, date);
drop function if exists public._amc_visit_unavailable_reason(uuid, date);

notify pgrst, 'reload schema';
commit;
