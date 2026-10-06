-- Rolled-back DB tests for Phase 2 gap 5 (migration 20261008140000_lead_cron_heartbeat). The migration is applied inside the
-- transaction (it is idempotent), the runner is replaced by stubs inside it, and everything ends in a RAISE: no real data is touched.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__T ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;


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

do $t$
declare txt text; ok boolean; rec record; v_cmd text;
begin
  -- Replace the runner INSIDE this rolled-back transaction so no real lead, follow-up or notification is touched.
  drop function if exists public.run_lead_followup_notifications(timestamptz, uuid);
  create function public.run_lead_followup_notifications(p_now timestamptz default now(), p_org_id uuid default null) returns jsonb language sql as $f$ select '{"noop": true}'::jsonb $f$;

  insert into cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values ('__TEST_job', now() - interval '2 hours', 'error', 'old failure', now() - interval '1 hour');
  perform public.lead_followup_cron_tick('__TEST_job');
  select * into rec from cron_job_heartbeats where job_key='__TEST_job';
  perform pg_temp.chk('success tick: status ok, error cleared, stale-alert cooldown cleared', rec.last_status='ok' and rec.last_error is null and rec.last_stale_alert_at is null);
  perform pg_temp.chk('success tick: last_run_at is now', rec.last_run_at > now() - interval '1 minute');

  -- a run that raises
  drop function public.run_lead_followup_notifications(timestamptz, uuid);
  create function public.run_lead_followup_notifications(p_now timestamptz default now(), p_org_id uuid default null) returns jsonb language plpgsql as $f$ begin raise exception 'boom: test failure'; end $f$;
  begin perform public.lead_followup_cron_tick('__TEST_job2'); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('a failing run does NOT propagate (the cron job itself stays healthy)', ok);
  select * into rec from cron_job_heartbeats where job_key='__TEST_job2';
  perform pg_temp.chk('failing tick: status error, message recorded', rec.last_status='error' and rec.last_error like '%boom: test failure%', coalesce(rec.last_error,''));
  perform pg_temp.chk('failing tick: last_run_at is now (the job is alive, its run failed)', rec.last_run_at > now() - interval '1 minute');
  perform public.lead_followup_cron_tick('__TEST_job2');
  perform pg_temp.chk('repeated failures keep a single row', (select count(*) from cron_job_heartbeats where job_key='__TEST_job2')=1);

  -- permissions
  for rec in select * from (values ('authenticated'),('anon')) x(r) loop
    begin
      perform set_config('request.jwt.claims', json_build_object('role', rec.r)::text, true);
      execute 'set local role ' || rec.r;
      perform public.lead_followup_cron_tick('__TEST_job3'); ok := true;
    exception when others then ok := false; end;
    execute 'reset role';
    perform pg_temp.chk('lead_followup_cron_tick not callable by ' || rec.r, ok = false);
  end loop;

  -- the schedule now points at the wrapper (same job, same cadence)
  select command into v_cmd from cron.job where jobname='lead-followup-notifications';
  perform pg_temp.chk('cron job runs the wrapper', v_cmd = 'select public.lead_followup_cron_tick()', v_cmd);
  perform pg_temp.chk('cron schedule unchanged (every 5 minutes)', (select schedule from cron.job where jobname='lead-followup-notifications') = '*/5 * * * *');
  perform pg_temp.chk('seed heartbeat row for the real job exists', exists (select 1 from cron_job_heartbeats where job_key='lead_followup_notifications'));

  select string_agg(r2.line, E'
' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS
%', txt;
end $t$;
