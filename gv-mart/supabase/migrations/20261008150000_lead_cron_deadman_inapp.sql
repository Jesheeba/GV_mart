-- Lead follow-up Phase 2, gap 5 (faster path): the in-app dead-man's switch.
--
-- The heartbeat of the pg_cron job 'lead-followup-notifications' (migration
-- 20261008140000) is also checked from followup_counts(), which every open master
-- tab polls once a minute. If the job is stale (no tick for 15 minutes) or its last
-- tick failed, AND the 6-hour cooldown has expired, the same master 'cron_job_stale'
-- in-app notification the GitHub-driven Edge check raises is created.
--
--  * One atomic UPDATE both tests the condition and starts the cooldown, so two tabs
--    polling at the same instant cannot both alert: the second waits on the row lock,
--    re-evaluates the condition, finds the cooldown set and updates nothing.
--  * Only the caller whose UPDATE returned a row inserts the notifications, in the same
--    transaction (an exception rolls back both, so a failed alert does not eat the cooldown).
--  * Shares last_stale_alert_at with the Edge-side check, so the two paths do not double-alert.
--  * Only a master's call reaches it; sales_admin callers do nothing and get the same output.
--  * followup_counts becomes VOLATILE (a stable function may not write). Same signature and
--    output, so the deployed frontend is unaffected; the extra work per poll is one
--    primary-key read of a tiny table.

create or replace function public._lead_cron_deadman_check(
  p_job_key text default 'lead_followup_notifications',
  p_org_id uuid default null
)
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
      and (h.last_run_at is null or h.last_run_at < v_now - interval '15 minutes' or h.last_status = 'error')
      and (h.last_stale_alert_at is null or h.last_stale_alert_at < v_now - interval '6 hours')
    returning h.last_run_at, h.last_status, h.last_error into v_last, v_status, v_err;
  if not found then
    return;
  end if;

  v_title := format('Cron job "%s" looks stuck', p_job_key);
  if v_last is null then
    v_body := format('%s: has never recorded a completed run', p_job_key);
  elsif v_now - v_last >= interval '15 minutes' then
    v_age := v_now - v_last;
    v_body := format('%s: last ran %s ago, expected every 5m', p_job_key,
      case when v_age < interval '2 hours' then round(extract(epoch from v_age) / 60)::text || 'm'
           else round(extract(epoch from v_age) / 3600)::text || 'h' end);
  else
    v_body := format('%s: still firing but its last run failed: %s', p_job_key, coalesce(v_err, 'unknown error'));
  end if;

  insert into public.notifications (org_id, role, type, title, body)
  select o.id, 'master', 'cron_job_stale', v_title, v_body
  from public.organizations o
  where p_org_id is null or o.id = p_org_id;
exception when others then
  -- never let the monitor break its caller; the sub-transaction (cooldown update + inserts) is rolled back
  null;
end;
$$;
revoke execute on function public._lead_cron_deadman_check(text, uuid) from public, anon, authenticated;

-- ── followup_counts: same body as 20261008130000 + the master-only check, now volatile ──
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
  -- Dead-man's switch: only a master's poll may raise the alert (see _lead_cron_deadman_check).
  -- sales_admin callers do nothing here and get the identical response.
  if public.current_role() = 'master' then
    begin
      perform public._lead_cron_deadman_check();
    exception when others then
      null; -- a broken monitor must never break the menu badge
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
