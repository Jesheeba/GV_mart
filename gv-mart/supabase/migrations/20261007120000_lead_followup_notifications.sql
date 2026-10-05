-- Lead follow-up notifications (Phase 1, commit 4) — in-app only.
--
--   1. Digest at the start of each working day (IST, settings.lead_work_start,
--      default 9:30): today's + overdue follow-ups, to master + sales_admin.
--   2. A reminder before an exact-time callback (settings.lead_reminder_minutes,
--      default 15).
--   3. A daily list of follow-ups overdue by more than 24 hours.
--   4. New-lead notifications now also reach master (they only went to
--      sales_admin).
--
-- Everything is computed by run_lead_followup_notifications(p_now), a plain SQL
-- function scheduled with pg_cron every 5 minutes (no HTTP hop, no secret).
-- p_now is a parameter so the logic can be tested at any simulated time.
-- Idempotent: lead_notification_log has a primary key on (kind, key), so a
-- delayed or repeated run never sends the same digest/reminder twice.
-- Recipients get one per-user row (user_id) — role-addressed rows can't be
-- marked read by an individual user.

-- ── 4. mirror new-lead notifications to master ───────────────────────────
create or replace function public._trg_mirror_lead_notification_to_master()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (new.org_id, 'master', new.type, new.title, new.body, new.ref_id);
  return null;
end;
$$;
revoke execute on function public._trg_mirror_lead_notification_to_master() from public, anon, authenticated;

create trigger notifications_mirror_lead_to_master
  after insert on public.notifications
  for each row
  when (new.role = 'sales_admin' and new.type in ('enquiry_lead', 'callback_requested', 'wa_lead_captured'))
  execute function public._trg_mirror_lead_notification_to_master();

-- ── 1–3. scheduled follow-up notifications ───────────────────────────────
create or replace function public.run_lead_followup_notifications(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org record;
  v_s record;
  v_today date := public._lead_ist_date(p_now);
  v_time time := (p_now at time zone 'Asia/Kolkata')::time;
  v_start time;
  v_end time;
  v_reminder integer;
  v_n_today integer;
  v_n_overdue integer;
  v_n_stale integer;
  v_names text;
  v_f record;
  v_digests integer := 0;
  v_reminders integer := 0;
  v_stale_sent integer := 0;
  v_key text;
begin
  for v_org in select id from public.organizations loop
    select * into v_s from public.settings where org_id = v_org.id;
    v_start := coalesce(v_s.lead_work_start, '09:30');
    v_end := coalesce(v_s.lead_work_end, '19:00');
    v_reminder := coalesce(v_s.lead_reminder_minutes, 15);

    -- Digest + stale list: once per working day, from opening time until closing.
    if public._lead_is_working_day(v_org.id, v_today) and v_time >= v_start and v_time <= v_end then
      v_key := v_org.id::text || ':' || v_today::text;

      -- 1. digest
      if not exists (select 1 from public.lead_notification_log where kind = 'digest' and key = v_key) then
        select
          count(*) filter (where public._lead_ist_date(f.due_at) = v_today),
          count(*) filter (where public._lead_ist_date(f.due_at) < v_today)
        into v_n_today, v_n_overdue
        from public.lead_followups f join public.leads l on l.id = f.lead_id
        where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost');

        insert into public.lead_notification_log (kind, key) values ('digest', v_key);
        if v_n_today + v_n_overdue > 0 then
          insert into public.notifications (org_id, user_id, type, title, body)
          select v_org.id, p.id, 'lead_followup_digest', 'Follow-ups for today',
                 format('%s due today, %s overdue. Open My Day.', v_n_today, v_n_overdue)
          from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
          v_digests := v_digests + 1;
        end if;
      end if;

      -- 3. overdue more than 24 hours
      if not exists (select 1 from public.lead_notification_log where kind = 'overdue24' and key = v_key) then
        select count(*), string_agg(name, ', ' order by due_at)
        into v_n_stale, v_names
        from (
          select coalesce(c.name, l.name) as name, f.due_at
          from public.lead_followups f join public.leads l on l.id = f.lead_id
          left join public.customers c on c.id = l.customer_id
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
            and f.due_at < p_now - interval '24 hours'
          order by f.due_at limit 5
        ) s;
        select count(*) into v_n_stale
        from public.lead_followups f join public.leads l on l.id = f.lead_id
        where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
          and f.due_at < p_now - interval '24 hours';

        insert into public.lead_notification_log (kind, key) values ('overdue24', v_key);
        if v_n_stale > 0 then
          insert into public.notifications (org_id, user_id, type, title, body)
          select v_org.id, p.id, 'lead_followup_overdue', 'Follow-ups overdue by more than 24 hours',
                 format('%s lead(s): %s%s', v_n_stale, v_names, case when v_n_stale > 5 then ' …' else '' end)
          from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
          v_stale_sent := v_stale_sent + 1;
        end if;
      end if;
    end if;

    -- 2. exact-time callback reminders (any day: staff may agree a Sunday call)
    for v_f in
      select f.id, f.due_at, l.id as lead_id, coalesce(c.name, l.name) as name, coalesce(l.mobile, c.mobile) as mobile
      from public.lead_followups f
      join public.leads l on l.id = f.lead_id
      left join public.customers c on c.id = l.customer_id
      where f.org_id = v_org.id and f.status = 'open' and f.is_exact_time and l.status not in ('won', 'lost')
        and f.due_at >= p_now and f.due_at <= p_now + make_interval(mins => v_reminder)
        and not exists (select 1 from public.lead_notification_log g where g.kind = 'reminder' and g.key = f.id::text)
    loop
      insert into public.lead_notification_log (kind, key) values ('reminder', v_f.id::text);
      insert into public.notifications (org_id, user_id, type, title, body, ref_id)
      select v_org.id, p.id, 'lead_callback_reminder',
             format('Callback in %s min: %s', greatest(1, ceil(extract(epoch from (v_f.due_at - p_now)) / 60)::int), v_f.name),
             format('%s%s at %s IST', v_f.name, coalesce(' (' || v_f.mobile || ')', ''), to_char(v_f.due_at at time zone 'Asia/Kolkata', 'HH12:MI AM')),
             v_f.lead_id
      from public.profiles p
      where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
      v_reminders := v_reminders + 1;
    end loop;
  end loop;

  return jsonb_build_object('digests', v_digests, 'reminders', v_reminders, 'overdue_lists', v_stale_sent, 'ran_at', p_now);
end;
$$;

-- Only the scheduler (postgres via pg_cron) and service_role may run it.
revoke execute on function public.run_lead_followup_notifications(timestamptz) from public, anon, authenticated;
grant execute on function public.run_lead_followup_notifications(timestamptz) to service_role;

-- ── pg_cron schedule (every 5 minutes) ───────────────────────────────────
create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'lead-followup-notifications') then
    perform cron.unschedule('lead-followup-notifications');
  end if;
  perform cron.schedule('lead-followup-notifications', '*/5 * * * *', 'select public.run_lead_followup_notifications()');
end
$$;
