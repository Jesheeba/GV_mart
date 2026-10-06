-- Rolled-back DB tests for the in-app cron dead-man's switch (migration 20261008150000). The migration is applied inside
-- the transaction (idempotent); part A uses '__TEST_*' heartbeat keys and a throwaway organisation; part B drives followup_counts()
-- against the real heartbeat key inside the transaction only. Ends in a RAISE: nothing persists.
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

do $t$
declare
  v_t uuid; m uuid; s uuid; txt text; ok boolean; n int; n2 int; cnt jsonb; cnt_s jsonb; v_row record; v_real_before timestamptz;
begin
  -- A throwaway organisation + throwaway master and sales_admin. Part A touches only '__TEST_*' heartbeat keys and that
  -- organisation's notifications. Part B exercises followup_counts() against the real heartbeat key INSIDE this rolled-back
  -- transaction (infrastructure row, nothing persists).
  insert into organizations (name) values ('__TEST_deadman_org') returning id into v_t;
  m := pg_temp.mkuser('master', v_t); s := pg_temp.mkuser('sales_admin', v_t);

  -- ===== A. the helper =====
  insert into cron_job_heartbeats (job_key, last_run_at, last_status) values ('__TEST_stale', now() - interval '40 minutes', 'ok');
  perform public._lead_cron_deadman_check('__TEST_stale', v_t);
  select count(*) into n from notifications where org_id = v_t and type = 'cron_job_stale' and role = 'master';
  perform pg_temp.chk('stale heartbeat: exactly one master cron_job_stale notification', n = 1, n::text);
  perform pg_temp.chk('alert text names the job and shows minutes', exists (select 1 from notifications where org_id = v_t and title = 'Cron job "__TEST_stale" looks stuck' and body = '__TEST_stale: last ran 40m ago, expected every 5m'),
    (select body from notifications where org_id = v_t limit 1));
  perform pg_temp.chk('cooldown started (last_stale_alert_at set)', (select last_stale_alert_at from cron_job_heartbeats where job_key = '__TEST_stale') > now() - interval '1 minute');
  perform public._lead_cron_deadman_check('__TEST_stale', v_t);
  perform public._lead_cron_deadman_check('__TEST_stale', v_t);
  select count(*) into n from notifications where org_id = v_t and type = 'cron_job_stale';
  perform pg_temp.chk('repeated checks inside the cooldown add nothing', n = 1, n::text);

  insert into cron_job_heartbeats (job_key, last_run_at, last_status) values ('__TEST_fresh', now() - interval '2 minutes', 'ok');
  perform public._lead_cron_deadman_check('__TEST_fresh', v_t);
  perform pg_temp.chk('fresh heartbeat (2 min): no alert', not exists (select 1 from notifications where org_id = v_t and title like '%__TEST_fresh%'));
  insert into cron_job_heartbeats (job_key, last_run_at, last_status) values ('__TEST_edge', now() - interval '14 minutes', 'ok');
  perform public._lead_cron_deadman_check('__TEST_edge', v_t);
  perform pg_temp.chk('14 minutes: still inside the window, no alert', not exists (select 1 from notifications where org_id = v_t and title like '%__TEST_edge%'));

  insert into cron_job_heartbeats (job_key, last_run_at, last_status, last_error) values ('__TEST_err', now() - interval '1 minute', 'error', 'boom: relation missing');
  perform public._lead_cron_deadman_check('__TEST_err', v_t);
  perform pg_temp.chk('recent tick that FAILED alerts with the error text', exists (select 1 from notifications where org_id = v_t and body = '__TEST_err: still firing but its last run failed: boom: relation missing'),
    coalesce((select body from notifications where org_id = v_t and title like '%__TEST_err%'), 'none'));

  insert into cron_job_heartbeats (job_key, last_run_at, last_status) values ('__TEST_never', null, 'ok');
  perform public._lead_cron_deadman_check('__TEST_never', v_t);
  perform pg_temp.chk('no completed run ever: "has never recorded a completed run"', exists (select 1 from notifications where org_id = v_t and body = '__TEST_never: has never recorded a completed run'));

  insert into cron_job_heartbeats (job_key, last_run_at, last_status) values ('__TEST_hours', now() - interval '3 hours', 'ok');
  perform public._lead_cron_deadman_check('__TEST_hours', v_t);
  perform pg_temp.chk('over two hours reads as hours', exists (select 1 from notifications where org_id = v_t and body = '__TEST_hours: last ran 3h ago, expected every 5m'));

  insert into cron_job_heartbeats (job_key, last_run_at, last_status, last_stale_alert_at) values ('__TEST_cool1', now() - interval '40 minutes', 'ok', now() - interval '1 hour');
  perform public._lead_cron_deadman_check('__TEST_cool1', v_t);
  perform pg_temp.chk('alerted 1h ago and still stale: no repeat', not exists (select 1 from notifications where org_id = v_t and title like '%__TEST_cool1%'));
  insert into cron_job_heartbeats (job_key, last_run_at, last_status, last_stale_alert_at) values ('__TEST_cool7', now() - interval '40 minutes', 'ok', now() - interval '7 hours');
  perform public._lead_cron_deadman_check('__TEST_cool7', v_t);
  perform pg_temp.chk('alerted 7h ago and still stale: alerts again', exists (select 1 from notifications where org_id = v_t and title like '%__TEST_cool7%'));

  perform public._lead_cron_deadman_check('__TEST_absent', v_t);
  perform pg_temp.chk('a key with no heartbeat row at all does nothing (no error)', (select count(*) from notifications where org_id = v_t and title like '%__TEST_absent%') = 0);

  -- permissions on the helper
  for v_row in select * from (values ('authenticated'), ('anon')) x(r) loop
    begin
      perform set_config('request.jwt.claims', json_build_object('role', v_row.r, 'sub', m)::text, true);
      execute 'set local role ' || v_row.r;
      perform public._lead_cron_deadman_check('__TEST_stale', v_t); ok := true;
    exception when others then ok := false; end;
    execute 'reset role';
    perform pg_temp.chk('_lead_cron_deadman_check not callable by ' || v_row.r, ok = false);
  end loop;

  -- ===== B. through followup_counts (real heartbeat key; rolled back) =====
  perform pg_temp.chk('followup_counts is VOLATILE now', (select provolatile from pg_proc where oid = 'public.followup_counts(text,uuid)'::regprocedure) = 'v');
  perform pg_temp.chk('same signature as before (text, uuid) and no extra overload', (select count(*) from pg_proc where proname = 'followup_counts' and pronamespace = 'public'::regnamespace) = 1);
  perform pg_temp.chk('followup_counts still not executable by anon', not has_function_privilege('anon', 'public.followup_counts(text,uuid)', 'execute') and has_function_privilege('authenticated', 'public.followup_counts(text,uuid)', 'execute'));

  update cron_job_heartbeats set last_run_at = now() - interval '30 minutes', last_status = 'ok', last_error = null, last_stale_alert_at = null where job_key = 'lead_followup_notifications';
  delete from notifications where created_at = now() and type = 'cron_job_stale';

  -- a sales_admin poll triggers nothing and learns nothing
  perform pg_temp.as_user(s);
  cnt_s := followup_counts();
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin poll: no notification and the cooldown is untouched',
    (select last_stale_alert_at from cron_job_heartbeats where job_key = 'lead_followup_notifications') is null
    and not exists (select 1 from notifications where type = 'cron_job_stale' and title like '%lead_followup_notifications%'));
  perform pg_temp.chk('sales_admin output has the usual keys and no sign of the monitor', (select array_agg(k order by k) from jsonb_object_keys(cnt_s) k) = array['by_person','overdue','today','total'], cnt_s::text);

  -- the master's poll raises it once
  perform pg_temp.as_user(m);
  cnt := followup_counts();
  perform pg_temp.as_pg();
  perform pg_temp.chk('master poll on a stale heartbeat: alert for the throwaway org (master role)', exists (select 1 from notifications where org_id = v_t and role = 'master' and type = 'cron_job_stale' and title = 'Cron job "lead_followup_notifications" looks stuck' and body like 'lead_followup_notifications: last ran 30m ago, expected every 5m'),
    coalesce((select body from notifications where org_id = v_t and title like '%lead_followup_notifications%' limit 1), 'none'));
  perform pg_temp.chk('master output has the same keys', (select array_agg(k order by k) from jsonb_object_keys(cnt) k) = array['by_person','overdue','today','total']);
  select count(*) into n from notifications where org_id = v_t and type = 'cron_job_stale' and title like '%lead_followup_notifications%';
  perform pg_temp.as_user(m); cnt := followup_counts(); cnt := followup_counts(); perform pg_temp.as_pg();
  select count(*) into n2 from notifications where org_id = v_t and type = 'cron_job_stale' and title like '%lead_followup_notifications%';
  perform pg_temp.chk('further master polls inside the cooldown add nothing', n = 1 and n2 = n, n::text || '/' || n2::text);
  perform pg_temp.chk('master and sales_admin see the same counts (same organisation, nothing assigned)', cnt->'total' = cnt_s->'total' and cnt->'overdue' = cnt_s->'overdue' and cnt->'today' = cnt_s->'today');

  -- a failing monitor must never break the badge: replace the helper with one that raises, poll again
  update cron_job_heartbeats set last_stale_alert_at = null where job_key = 'lead_followup_notifications';
  execute 'create or replace function public._lead_cron_deadman_check(p_job_key text default ''x'', p_org_id uuid default null) returns void language plpgsql as $f$ begin raise exception ''monitor exploded''; end $f$';
  perform pg_temp.as_user(m);
  begin cnt := followup_counts(); ok := true; exception when others then ok := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('followup_counts still answers when the monitor raises', ok and (cnt->>'total') is not null);

  select string_agg(r2.line, E'
' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS
%', txt;
end $t$;
