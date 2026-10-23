-- Audit reconciliation, scheduled. A detector that stops running
-- silently is worse than none — it creates false confidence. Reuses the
-- EXISTING heartbeat/dead-man's-switch pattern from
-- 20260924110000_cron_job_heartbeats.sql + 20261008140000/150000 (the
-- lead-followup cron), rather than inventing a new one:
--   * one row per job in the existing cron_job_heartbeats table,
--     written on every tick, success or failure
--   * a dead-man's-switch function that fires an in-app 'cron_job_stale'
--     notification to master if the heartbeat goes stale or errors,
--     with its own cooldown so it doesn't spam
-- Thresholds are scaled for a daily job instead of lead-followup's every-
-- 5-minutes one: stale after 26 hours (a day plus slack for a slow run),
-- cooldown 24 hours (one alert per missed day, not one per poll).
--
-- Two differences from the lead-followup version, both deliberate:
--   1. The lead pattern's in-app leg piggybacks on followup_counts(),
--      which masters poll every minute anyway. There's no equivalent
--      high-frequency master-polled endpoint for this feature, so the
--      in-app leg here piggybacks on audit_reconciliation_report()
--      itself — real traffic, but only whenever a master actually opens
--      the report, which is not guaranteed to be often.
--   2. To cover the case where nobody opens the report for a while
--      either, a second pg_cron job also runs the dead-man's-switch
--      directly on a fixed interval (every 2 hours), independent of
--      anyone polling anything. Belt and suspenders: if pg_cron itself
--      has died, this second job doesn't fire either, but then neither
--      does the primary daily job, and the in-app leg is what's left
--      covering that case — the same resilience property the lead
--      pattern relies on its in-app leg for.

create or replace function public.audit_reconciliation_cron_tick(p_job_key text default 'audit_reconciliation_daily')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moved_count int;
  v_summary text;
begin
  begin
    select count(*), string_agg(format('%s (%s -> %s)', table_name, baseline_difference, difference), ', ')
      into v_moved_count, v_summary
    from public.audit_reconciliation_report()
    where moved_since_baseline;

    if v_moved_count > 0 then
      insert into public.notifications (org_id, role, type, title, body)
      select o.id, 'master', 'audit_reconciliation_drift',
        format('Audit reconciliation: %s table(s) moved since baseline', v_moved_count),
        v_summary
      from public.organizations o;
    end if;
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

revoke execute on function public.audit_reconciliation_cron_tick(text) from public, anon, authenticated;

-- First heartbeat now, so the dead-man's-switch does not report "never
-- recorded a completed run" in the window before the first scheduled tick.
insert into public.cron_job_heartbeats (job_key, last_run_at, last_status)
values ('audit_reconciliation_daily', clock_timestamp(), 'ok')
on conflict (job_key) do nothing;

-- Same shape as _lead_cron_deadman_check, thresholds scaled for daily.
create or replace function public._audit_reconciliation_deadman_check(p_job_key text default 'audit_reconciliation_daily')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_last timestamptz;
  v_status text;
  v_err text;
  v_title text;
  v_body text;
  v_age interval;
begin
  update public.cron_job_heartbeats h
    set last_stale_alert_at = v_now
    where h.job_key = p_job_key
      and (h.last_run_at is null or h.last_run_at < v_now - interval '26 hours' or h.last_status = 'error')
      and (h.last_stale_alert_at is null or h.last_stale_alert_at < v_now - interval '24 hours')
    returning h.last_run_at, h.last_status, h.last_error into v_last, v_status, v_err;
  if not found then
    return;
  end if;

  v_title := format('Cron job "%s" looks stuck', p_job_key);
  if v_last is null then
    v_body := format('%s: has never recorded a completed run', p_job_key);
  elsif v_now - v_last >= interval '26 hours' then
    v_age := v_now - v_last;
    v_body := format('%s: last ran %s ago, expected daily', p_job_key, round(extract(epoch from v_age) / 3600)::text || 'h');
  else
    v_body := format('%s: still firing but its last run failed: %s', p_job_key, coalesce(v_err, 'unknown error'));
  end if;

  insert into public.notifications (org_id, role, type, title, body)
  select o.id, 'master', 'cron_job_stale', v_title, v_body
  from public.organizations o;
exception when others then
  null;
end;
$$;

revoke execute on function public._audit_reconciliation_deadman_check(text) from public, anon, authenticated;

-- audit_reconciliation_report, + the in-app dead-man's-switch leg. Same
-- body as 20261024100800's version, with the check added right after
-- the master-role guard (so it fires on every real call a master makes,
-- same "whoever's traffic happens to hit it" idea as followup_counts).
create or replace function public.audit_reconciliation_report()
returns table (
  table_name text,
  live_count bigint,
  net_audit_count bigint,
  difference bigint,
  baseline_difference bigint,
  moved_since_baseline boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_live bigint;
  v_net bigint;
  v_baseline bigint;
begin
  if not public.is_master() then
    raise exception 'audit_reconciliation_report: master role required';
  end if;

  begin
    perform public._audit_reconciliation_deadman_check();
  exception when others then
    null; -- a broken monitor must never break the report it is monitoring
  end;

  for r in
    select distinct c.relname as tbl
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
    where p.proname = 'audit_master_change'
      and not t.tgisinternal
    order by 1
  loop
    execute format('select count(*) from public.%I', r.tbl) into v_live;
    select coalesce(count(*) filter (where audit_log.action = 'INSERT'), 0) - coalesce(count(*) filter (where audit_log.action = 'DELETE'), 0)
      into v_net
    from public.audit_log
    where audit_log.table_name = r.tbl;

    select b.diff into v_baseline
    from public.audit_reconciliation_baseline b
    where b.table_name = r.tbl
    order by b.captured_at desc
    limit 1;

    table_name := r.tbl;
    live_count := v_live;
    net_audit_count := v_net;
    difference := v_live - v_net;
    baseline_difference := v_baseline;
    moved_since_baseline := (v_baseline is null) or (difference is distinct from v_baseline);
    return next;
  end loop;
end;
$$;

grant execute on function public.audit_reconciliation_report() to authenticated;
revoke execute on function public.audit_reconciliation_report() from public, anon;

-- Two pg_cron jobs, not GitHub Actions — this runs entirely inside
-- Postgres (SECURITY DEFINER, master-gated), no external credential, no
-- public-repo exposure, unlike the backup job proposal.
select cron.schedule('audit-reconciliation-daily', '47 20 * * *', 'select public.audit_reconciliation_cron_tick()');
-- Kept, not replaced: this remains the only coverage for a pg_cron
-- scheduler that has died entirely (the in-app leg below depends on
-- pg_cron still being alive to run the DAILY job in the first place;
-- this 2-hourly job is independent of whether anyone opens the report).
select cron.schedule('audit-reconciliation-deadman', '0 */2 * * *', 'select public._audit_reconciliation_deadman_check()');

-- Rides followup_counts() too, same anchor the lead dead-man's-switch
-- already uses: polled by any open master tab roughly once a minute,
-- independent of pg_cron's own health. Same body as 20261008150000,
-- with the audit-reconciliation check added alongside the existing lead
-- one inside the same "only a master's poll may raise" guard — one
-- extra heartbeat read per poll, and the existing cooldown-gated atomic
-- UPDATE inside _audit_reconciliation_deadman_check already prevents two
-- concurrent pollers (or this leg racing the 2-hourly cron tick) from
-- double-alerting, the same way it already does for the lead check.
create or replace function public.followup_counts(p_scope text default 'auto', p_assignee uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_scope text;
  v_overdue int;
  v_today_n int;
  v_people jsonb := '[]'::jsonb;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  -- Dead-man's switches: only a master's poll may raise either alert.
  -- sales_admin callers do nothing here and get the identical response.
  if public.current_role() = 'master' then
    begin
      perform public._lead_cron_deadman_check();
    exception when others then
      null; -- a broken monitor must never break the menu badge
    end;
    begin
      perform public._audit_reconciliation_deadman_check();
    exception when others then
      null;
    end;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  select
    count(*) filter (where public._lead_ist_date(f.due_at) < v_today),
    count(*) filter (where public._lead_ist_date(f.due_at) = v_today)
  into v_overdue, v_today_n
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost')
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    );

  -- master: who holds how much (assignees only; unassigned is the remainder)
  if public.current_role() = 'master' then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.full_name, 'overdue', x.o, 'today', x.t) order by x.full_name), '[]'::jsonb)
    into v_people
    from (
      select ap.id, ap.full_name,
        count(*) filter (where public._lead_ist_date(f.due_at) < v_today) as o,
        count(*) filter (where public._lead_ist_date(f.due_at) = v_today) as t
      from public.lead_followups f
      join public.leads l on l.id = f.lead_id
      join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
      where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost')
      group by ap.id, ap.full_name
    ) x;
  end if;

  return jsonb_build_object('overdue', v_overdue, 'today', v_today_n, 'total', v_overdue + v_today_n, 'by_person', v_people);
end;
$$;

revoke execute on function public.followup_counts(text, uuid) from public, anon;
grant execute on function public.followup_counts(text, uuid) to authenticated;
