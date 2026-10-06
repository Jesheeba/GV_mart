-- Lead follow-up Phase 2: "No follow-up" - find, schedule (one or in bulk) and digest the
-- open leads that nobody has scheduled (e.g. after the placeholder Initial calls were removed).
--
-- Additive; the currently deployed frontend is unaffected:
--   * list_leads_without_followup: new function (scope rules identical to My Day).
--   * set_lead_followups_bulk: new function. Spread mode reuses the backfill's slot maths
--     (oldest lead first, N per day, evenly spread between work start + 30 min and work end - 1 h
--     on 5-minute marks, working days only).
--   * set_lead_followup: SAME signature, now also refuses a sales_admin on a lead that is
--     assigned to someone else (master: any lead; sales_admin: own + unassigned, same as assign_lead).
--   * run_lead_followup_notifications: the digest gains " N lead(s) have no follow-up." and is also
--     sent when that is the only thing to report. With no such leads its output is unchanged.

-- who may schedule a follow-up on this lead (master: any; sales_admin: own + effectively unassigned)
create or replace function public._lead_set_followup_allowed(p_lead public.leads)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case public.current_role()
    when 'master' then true
    when 'sales_admin' then
      p_lead.assigned_to is null
      or p_lead.assigned_to = auth.uid()
      or not exists (select 1 from public.profiles ap
                     where ap.id = p_lead.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin') and ap.org_id = p_lead.org_id)
    else false
  end
$$;
revoke execute on function public._lead_set_followup_allowed(public.leads) from public, anon, authenticated;

-- ── set_lead_followup: + ownership rule (everything else as in 20261006210000) ──
create or replace function public.set_lead_followup(
  p_lead_id uuid,
  p_due_at timestamptz,
  p_type public.lead_followup_type default 'call',
  p_note text default null,
  p_is_exact boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_id uuid;
begin
  v_lead := public._lead_lock(p_lead_id);
  if v_lead.status in ('won', 'lost') then
    raise exception 'this lead is already %; reopen it first', v_lead.status;
  end if;
  if not public._lead_set_followup_allowed(v_lead) then
    raise exception 'this lead is assigned to someone else';
  end if;
  if exists (select 1 from public.lead_followups where lead_id = v_lead.id and status = 'open') then
    raise exception 'this lead already has an open follow-up';
  end if;
  perform public._lead_check_due(p_due_at);

  insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source)
  values (v_lead.org_id, v_lead.id, p_due_at, coalesce(p_type, 'call'), coalesce(p_is_exact, false), nullif(btrim(coalesce(p_note, '')), ''), 'manual')
  returning id into v_id;
  return v_id;
end;
$$;

-- ── list_leads_without_followup ──────────────────────────────────────────
create or replace function public.list_leads_without_followup(
  p_stage public.lead_status default null,
  p_source text default null,
  p_kind public.lead_kind default null,
  p_scope text default 'auto',
  p_assignee uuid default null
)
returns table (
  lead_id uuid,
  lead_name text,
  mobile text,
  source text,
  kind public.lead_kind,
  enquiry_type public.enquiry_type,
  lead_status public.lead_status,
  product_name text,
  created_at timestamptz,
  postpone_count integer,
  assignee_id uuid,
  assignee_name text,
  last_outcome_label_en text,
  last_outcome_label_ta text,
  last_outcome_note text,
  last_outcome_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view leads without a follow-up';
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  return query
  select
    l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, l.kind, l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    l.created_at, l.postpone_count, ap.id, ap.full_name,
    lo.label_en, lo.label_ta, lo.note, lo.at
  from public.leads l
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where l.org_id = v_org and l.status not in ('won', 'lost')
    and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or l.kind = p_kind)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
  order by l.created_at asc, l.id asc;
end;
$$;
revoke execute on function public.list_leads_without_followup(public.lead_status, text, public.lead_kind, text, uuid) from public, anon;
grant execute on function public.list_leads_without_followup(public.lead_status, text, public.lead_kind, text, uuid) to authenticated;

-- ── set_lead_followups_bulk ──────────────────────────────────────────────
-- p_per_day NULL : every eligible lead gets p_due_at (validated like set_lead_followup).
-- p_per_day N    : "spread": the first working day on or after max(p_due_at's IST date, tomorrow)
--                  and following working days, N leads a day, oldest lead first, evenly spread
--                  between work start + 30 min and work end - 1 hour on 5-minute marks.
-- A lead is skipped (never an error for the whole batch) when it is missing, closed, already has an
-- open follow-up, or is assigned to someone else the caller may not schedule for.
create or replace function public.set_lead_followups_bulk(
  p_lead_ids uuid[],
  p_due_at timestamptz,
  p_type public.lead_followup_type default 'call',
  p_note text default null,
  p_per_day integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_ids uuid[];
  v_lead public.leads;
  v_id uuid;
  v_skipped jsonb := '[]'::jsonb;
  v_eligible uuid[] := '{}';
  v_s record;
  v_open time;
  v_close time;
  v_start_day date;
  v_day date;
  v_n integer;
  v_k integer;
  v_pos integer;
  v_cnt integer;
  v_created integer := 0;
  v_first date;
  v_last date;
  v_due timestamptz;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can schedule follow-ups';
  end if;
  select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(coalesce(p_lead_ids, '{}')) x;
  if cardinality(v_ids) = 0 then
    raise exception 'choose at least one lead';
  end if;
  if cardinality(v_ids) > 200 then
    raise exception 'at most 200 leads at a time';
  end if;
  if p_per_day is not null and (p_per_day < 1 or p_per_day > 100) then
    raise exception 'leads per day must be between 1 and 100';
  end if;
  if p_per_day is null then
    perform public._lead_check_due(p_due_at);
  elsif p_due_at is null then
    raise exception 'a start date is required';
  end if;

  -- 1. who is eligible (locked in id order so concurrent batches cannot deadlock)
  for v_lead in
    select * from public.leads where id = any(v_ids) and org_id = v_org order by id for update
  loop
    if v_lead.status in ('won', 'lost') then
      v_skipped := v_skipped || jsonb_build_object('lead_id', v_lead.id, 'reason', 'closed');
    elsif not public._lead_set_followup_allowed(v_lead) then
      v_skipped := v_skipped || jsonb_build_object('lead_id', v_lead.id, 'reason', 'not_yours');
    elsif exists (select 1 from public.lead_followups f where f.lead_id = v_lead.id and f.status = 'open') then
      v_skipped := v_skipped || jsonb_build_object('lead_id', v_lead.id, 'reason', 'has_followup');
    else
      v_eligible := v_eligible || v_lead.id;
    end if;
  end loop;
  select v_skipped || coalesce(jsonb_agg(jsonb_build_object('lead_id', x, 'reason', 'not_found')), '[]'::jsonb)
  into v_skipped
  from unnest(v_ids) x where not exists (select 1 from public.leads l where l.id = x and l.org_id = v_org);

  v_n := cardinality(v_eligible);
  if v_n > 0 then
    if p_per_day is null then
      for v_s in select id from public.leads where id = any(v_eligible) order by created_at, id loop
        insert into public.lead_followups (org_id, lead_id, due_at, type, note, source)
        values (v_org, v_s.id, p_due_at, coalesce(p_type, 'call'), v_note, 'manual');
        v_created := v_created + 1;
      end loop;
    else
      select coalesce(s.lead_work_start, '09:30') + interval '30 minutes', coalesce(s.lead_work_end, '19:00') - interval '1 hour'
      into v_open, v_close from public.settings s where s.org_id = v_org;
      v_open := coalesce(v_open, '10:00'::time);
      v_close := coalesce(v_close, '18:00'::time);
      v_start_day := greatest(public._lead_ist_date(p_due_at), public._lead_ist_date(now()) + 1);
      if not public._lead_is_working_day(v_org, v_start_day) then
        v_start_day := public.lead_next_working_day(v_org, v_start_day);
      end if;
      v_day := v_start_day;
      v_first := v_start_day;
      v_k := 0;
      for v_s in select id from public.leads where id = any(v_eligible) order by created_at, id loop
        v_pos := v_k % p_per_day;
        if v_k > 0 and v_pos = 0 then
          v_day := public.lead_next_working_day(v_org, v_day);
        end if;
        v_cnt := least(p_per_day, v_n - (v_k / p_per_day) * p_per_day);
        v_due := public._lead_ist_ts(
          v_day,
          v_open + make_interval(mins => (floor((v_pos * (extract(epoch from (v_close - v_open)) / 60.0 / v_cnt)) / 5) * 5)::int)
        );
        insert into public.lead_followups (org_id, lead_id, due_at, type, note, source)
        values (v_org, v_s.id, v_due, coalesce(p_type, 'call'), v_note, 'manual');
        v_created := v_created + 1;
        v_last := v_day;
        v_k := v_k + 1;
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'created', v_created, 'skipped', v_skipped, 'per_day', p_per_day,
    'first_day', v_first, 'last_day', v_last
  );
end;
$$;
revoke execute on function public.set_lead_followups_bulk(uuid[], timestamptz, public.lead_followup_type, text, integer) from public, anon;
grant execute on function public.set_lead_followups_bulk(uuid[], timestamptz, public.lead_followup_type, text, integer) to authenticated;

-- ── digest: + "N lead(s) have no follow-up." ─────────────────────────────
create or replace function public.run_lead_followup_notifications(p_now timestamptz default now(), p_org_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
            v_body := format('%s due today, %s overdue. Open My Day.', v_n_today, v_n_overdue);
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
$$;

revoke execute on function public.run_lead_followup_notifications(timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.run_lead_followup_notifications(timestamptz, uuid) to service_role;
