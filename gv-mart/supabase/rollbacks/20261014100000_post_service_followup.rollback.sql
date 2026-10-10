-- Rollback for 20261014100000_post_service_followup.sql. Post-service follow-ups, call history and the master list are DELETED.
-- Export first if you want to keep them:
--   select * from lead_followups where ticket_id is not null;  select * from post_service_calls;
drop trigger if exists service_tickets_post_service_followup on public.service_tickets;
drop function if exists public._trg_ticket_post_service_followup();
drop function if exists public.log_post_service_call(uuid, uuid, text, timestamptz);
drop function if exists public.list_post_service_followups(text, text, uuid);

-- live bodies as they were before this migration
create or replace function public.followup_counts(p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

create or replace function public.run_lead_followup_notifications(p_now timestamp with time zone DEFAULT now(), p_org_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org record;
  v_s record;
  v_r record;
  v_today date := public._lead_ist_date(p_now);
  v_time time := (p_now at time zone 'Asia/Kolkata')::time;
  v_start time;
  v_end time;
  v_reminder integer;
  v_n_today integer;
  v_n_overdue integer;
  v_n_stale integer;
  v_n_none integer;
  v_names text;
  v_people text;
  v_unassigned integer;
  v_body text;
  v_f record;
  v_digests integer := 0;
  v_reminders integer := 0;
  v_stale_sent integer := 0;
  v_sent_any boolean;
  v_key text;
begin
  for v_org in select id from public.organizations where p_org_id is null or id = p_org_id loop
    select * into v_s from public.settings where org_id = v_org.id;
    v_start := coalesce(v_s.lead_work_start, '09:30');
    v_end := coalesce(v_s.lead_work_end, '19:00');
    v_reminder := coalesce(v_s.lead_reminder_minutes, 15);

    -- Digest + stale list: once per working day, from opening time until closing.
    if public._lead_is_working_day(v_org.id, v_today) and v_time >= v_start and v_time <= v_end then
      v_key := v_org.id::text || ':' || v_today::text;

      -- 1. digest
      if not exists (select 1 from public.lead_notification_log where kind = 'digest' and key = v_key) then
        insert into public.lead_notification_log (kind, key) values ('digest', v_key);
        v_sent_any := false;
        for v_r in
          select p.id, p.role from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        loop
          select
            count(*) filter (where public._lead_ist_date(f.due_at) = v_today),
            count(*) filter (where public._lead_ist_date(f.due_at) < v_today)
          into v_n_today, v_n_overdue
          from public.lead_followups f
          join public.leads l on l.id = f.lead_id
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
            and (v_r.role = 'master' or ap.id is null or ap.id = v_r.id);

          -- open leads nobody has scheduled (same visibility rule as the counts above)
          select count(*) into v_n_none
          from public.leads l
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where l.org_id = v_org.id and l.status not in ('won', 'lost')
            and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
            and (v_r.role = 'master' or ap.id is null or ap.id = v_r.id);

          if v_n_today + v_n_overdue + v_n_none > 0 then
            v_body := format('%s due today, %s overdue. Open Daily Follow Up.', v_n_today, v_n_overdue);
            if v_r.role = 'master' then
              select count(*) filter (where ap.id is null) into v_unassigned
              from public.lead_followups f
              join public.leads l on l.id = f.lead_id
              left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
              where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
                and public._lead_ist_date(f.due_at) <= v_today;
              select string_agg(format('%s %s', x.full_name, x.n), ', ' order by x.full_name) into v_people
              from (
                select ap.full_name, count(*) as n
                from public.lead_followups f
                join public.leads l on l.id = f.lead_id
                join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
                where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
                  and public._lead_ist_date(f.due_at) <= v_today
                group by ap.id, ap.full_name
              ) x;
              if v_people is not null then
                v_body := v_body || format(' Unassigned: %s. By person: %s.', v_unassigned, v_people);
              end if;
            end if;
            if v_n_none > 0 then
              v_body := v_body || format(' %s lead(s) have no follow-up.', v_n_none);
            end if;
            insert into public.notifications (org_id, user_id, type, title, body)
            values (v_org.id, v_r.id, 'lead_followup_digest', 'Follow-ups for today', v_body);
            v_sent_any := true;
          end if;
        end loop;
        if v_sent_any then
          v_digests := v_digests + 1;
        end if;
      end if;

      -- 3. overdue more than 24 hours
      if not exists (select 1 from public.lead_notification_log where kind = 'overdue24' and key = v_key) then
        insert into public.lead_notification_log (kind, key) values ('overdue24', v_key);
        v_sent_any := false;
        for v_r in
          select p.id, p.role from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        loop
          -- the recipient's own list: sales_admin = own + unassigned, master = own + unassigned
          select count(*), string_agg(name, ', ' order by due_at)
          into v_n_stale, v_names
          from (
            select coalesce(c.name, l.name) as name, f.due_at
            from public.lead_followups f
            join public.leads l on l.id = f.lead_id
            left join public.customers c on c.id = l.customer_id
            left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
            where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
              and f.due_at < p_now - interval '24 hours'
              and (ap.id is null or ap.id = v_r.id)
            order by f.due_at limit 5
          ) s;
          select count(*) into v_n_stale
          from public.lead_followups f
          join public.leads l on l.id = f.lead_id
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
            and f.due_at < p_now - interval '24 hours'
            and (ap.id is null or ap.id = v_r.id);

          v_people := null;
          if v_r.role = 'master' then
            -- colleagues' overdue counts (master sees counts, not their lists)
            select string_agg(format('%s %s', x.full_name, x.n), ', ' order by x.full_name) into v_people
            from (
              select ap.full_name, count(*) as n
              from public.lead_followups f
              join public.leads l on l.id = f.lead_id
              join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin') and ap.id <> v_r.id
              where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
                and f.due_at < p_now - interval '24 hours'
              group by ap.id, ap.full_name
            ) x;
          end if;

          if v_n_stale > 0 or v_people is not null then
            v_body := case when v_n_stale > 0 then format('%s lead(s): %s%s', v_n_stale, v_names, case when v_n_stale > 5 then ' …' else '' end) else null end;
            if v_people is not null then
              v_body := coalesce(v_body || ' · ', '') || 'By person: ' || v_people;
            end if;
            insert into public.notifications (org_id, user_id, type, title, body)
            values (v_org.id, v_r.id, 'lead_followup_overdue', 'Follow-ups overdue by more than 24 hours', v_body);
            v_sent_any := true;
          end if;
        end loop;
        if v_sent_any then
          v_stale_sent := v_stale_sent + 1;
        end if;
      end if;
    end if;

    -- 2. exact-time callback reminders (any day: staff may agree a Sunday call)
    for v_f in
      select f.id, f.due_at, l.id as lead_id, coalesce(c.name, l.name) as name, coalesce(l.mobile, c.mobile) as mobile, ap.id as assignee_id
      from public.lead_followups f
      join public.leads l on l.id = f.lead_id
      left join public.customers c on c.id = l.customer_id
      left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
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
      where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        and (v_f.assignee_id is null or p.id = v_f.assignee_id);
      v_reminders := v_reminders + 1;
    end loop;
  end loop;

  return jsonb_build_object('digests', v_digests, 'reminders', v_reminders, 'overdue_lists', v_stale_sent, 'ran_at', p_now);
end;
$function$;

drop table if exists public.post_service_calls;
drop trigger if exists seed_post_service_outcomes_on_org on public.organizations;
drop function if exists public.trg_seed_post_service_outcomes();
drop table if exists public.post_service_outcomes;
drop function if exists public._trg_post_service_outcome_guard();
drop function if exists public.seed_post_service_outcomes(uuid);

alter table public.settings drop constraint if exists settings_post_service_types_valid;
alter table public.settings drop constraint if exists settings_post_service_dedupe_range;
alter table public.settings drop constraint if exists settings_post_service_days_range;
alter table public.settings drop column if exists post_service_dedupe_days;
alter table public.settings drop column if exists post_service_ticket_types;
alter table public.settings drop column if exists post_service_followup_assignee;
alter table public.settings drop column if exists post_service_followup_days;
alter table public.settings drop column if exists post_service_followup_enabled;

delete from public.lead_followups where ticket_id is not null;
drop index if exists public.lead_followups_ticket_open_idx;
drop index if exists public.lead_followups_one_per_ticket;
alter table public.lead_followups drop constraint if exists lead_followups_lead_xor_ticket;
alter table public.lead_followups drop column if exists assigned_to;
alter table public.lead_followups drop column if exists customer_id;
alter table public.lead_followups drop column if exists ticket_id;
alter table public.lead_followups alter column lead_id set not null;

notify pgrst, 'reload schema';
