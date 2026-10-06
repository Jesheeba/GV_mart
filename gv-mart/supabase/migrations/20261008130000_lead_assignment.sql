-- Lead follow-up Phase 2, gap 3: per-person lead assignment + assignee-aware
-- My Day, digest, reminders and overdue lists.
--
-- COMPATIBILITY with the deployed frontend:
--   * leads.assigned_to is nullable; every existing lead stays unassigned.
--   * list_followups / followup_counts / run_lead_followup_notifications gain
--     trailing arguments WITH DEFAULTS. The old signatures are dropped in this
--     same migration (two overloads that both accept the old call shape would be
--     "not unique" for PostgREST), so current calls resolve to the new functions.
--   * Resolution of "auto" scope: master sees everything (as today); sales_admin
--     sees their own leads plus unassigned ones. With nothing assigned that is
--     every lead, i.e. exactly today's behaviour.
--
-- "Effectively unassigned" = assigned_to is null OR the assignee is no longer an
-- active master/sales_admin. Such leads fall back to everyone who can pick them up.

-- ── leads.assigned_to ────────────────────────────────────────────────────
alter table public.leads
  add column assigned_to uuid references public.profiles (id) on delete set null;

create index leads_assigned_to_idx on public.leads (org_id, assigned_to) where assigned_to is not null;

-- ── assignment history (append-only; written only by assign_lead) ────────
create table public.lead_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  lead_id uuid not null references public.leads (id) on delete cascade,
  from_user uuid references public.profiles (id) on delete set null,
  -- NULL = the lead was unassigned
  to_user uuid references public.profiles (id) on delete set null,
  assigned_by uuid references public.profiles (id) on delete set null default auth.uid(),
  reason text,
  created_at timestamptz not null default clock_timestamp()
);
create index lead_assignments_lead_idx on public.lead_assignments (lead_id, created_at);

alter table public.lead_assignments enable row level security;
create policy lead_assignments_select_master on public.lead_assignments
  for select using (org_id = public.current_org_id() and public.is_master());
-- no insert/update/delete policies: assign_lead (SECURITY DEFINER) is the only writer.

create or replace function public._trg_lead_assignments_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- a deleted lead cascades its history; nothing else may change or remove a row
  if tg_op = 'DELETE' and not exists (select 1 from public.leads where id = old.lead_id) then
    return old;
  end if;
  -- profile deletion sets the user columns to NULL (ON DELETE SET NULL)
  if tg_op = 'UPDATE' and (
       (new.from_user is null and old.from_user is not null and not exists (select 1 from public.profiles where id = old.from_user))
    or (new.to_user is null and old.to_user is not null and not exists (select 1 from public.profiles where id = old.to_user))
    or (new.assigned_by is null and old.assigned_by is not null and not exists (select 1 from public.profiles where id = old.assigned_by))
  ) and (to_jsonb(new) - 'from_user' - 'to_user' - 'assigned_by') = (to_jsonb(old) - 'from_user' - 'to_user' - 'assigned_by') then
    return new;
  end if;
  raise exception 'lead_assignments is append-only';
end;
$$;
revoke execute on function public._trg_lead_assignments_immutable() from public, anon, authenticated;
create trigger lead_assignments_immutable
  before update or delete on public.lead_assignments
  for each row execute function public._trg_lead_assignments_immutable();

-- ── guard: assigned_to changes only through assign_lead ──────────────────
-- (leads_update_sales lets staff update any column of a lead directly, so the
-- permission rules have to live here, not only in the RPC.)
create or replace function public._trg_lead_assigned_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.lead_assign_ok', true), '') = '1' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.assigned_to is not null then
      raise exception 'leads are created unassigned; use assign_lead';
    end if;
    return new;
  end if;
  if new.assigned_to is distinct from old.assigned_to then
    -- ON DELETE SET NULL after the assignee's profile was removed
    if new.assigned_to is null and not exists (select 1 from public.profiles where id = old.assigned_to) then
      return new;
    end if;
    raise exception 'assigned_to can only be changed with assign_lead';
  end if;
  return new;
end;
$$;
revoke execute on function public._trg_lead_assigned_guard() from public, anon, authenticated;
create trigger leads_assigned_guard
  before insert or update of assigned_to on public.leads
  for each row execute function public._trg_lead_assigned_guard();

-- ── assign_lead ──────────────────────────────────────────────────────────
-- master: assign / reassign / unassign (p_assignee null) anyone.
-- sales_admin: pick up an effectively-unassigned lead (assignee = themselves) or
--   hand their OWN lead to a colleague; never take or move someone else's lead.
-- The assignee must be an active master or sales_admin of the same organisation.
create or replace function public.assign_lead(p_lead_id uuid, p_assignee uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_role public.user_role := public.current_role();
  v_uid uuid := auth.uid();
  v_cur_active boolean;
  v_target public.profiles;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_by_name text;
begin
  v_lead := public._lead_lock(p_lead_id);

  if v_lead.status in ('won', 'lost') then
    raise exception 'only an open lead can be assigned; reopen it first';
  end if;

  v_cur_active := v_lead.assigned_to is not null and exists (
    select 1 from public.profiles where id = v_lead.assigned_to and is_active and role in ('master', 'sales_admin') and org_id = v_lead.org_id);

  if p_assignee is null then
    if v_role <> 'master' then
      raise exception 'only the master can unassign a lead';
    end if;
    if v_lead.assigned_to is null then
      raise exception 'this lead is already unassigned';
    end if;
  else
    select * into v_target from public.profiles where id = p_assignee and org_id = v_lead.org_id;
    if not found or not v_target.is_active or v_target.role not in ('master', 'sales_admin') then
      raise exception 'a lead can only be assigned to an active master or sales_admin';
    end if;
    if v_lead.assigned_to = p_assignee then
      raise exception 'this lead is already assigned to that person';
    end if;
  end if;

  if v_role = 'sales_admin' then
    if not v_cur_active then
      if p_assignee is distinct from v_uid then
        raise exception 'you can only pick up an unassigned lead for yourself';
      end if;
    elsif v_lead.assigned_to = v_uid then
      if p_assignee is null or p_assignee = v_uid then
        raise exception 'hand your lead to a colleague';
      end if;
    else
      raise exception 'this lead is assigned to someone else';
    end if;
  end if;

  perform set_config('app.lead_assign_ok', '1', true);
  update public.leads set assigned_to = p_assignee where id = v_lead.id;
  perform set_config('app.lead_assign_ok', '', true);

  insert into public.lead_assignments (org_id, lead_id, from_user, to_user, assigned_by, reason)
  values (v_lead.org_id, v_lead.id, v_lead.assigned_to, p_assignee, v_uid, v_reason);

  if p_assignee is not null and p_assignee <> v_uid then
    select full_name into v_by_name from public.profiles where id = v_uid;
    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (
      v_lead.org_id, p_assignee, 'lead_assigned', 'A lead was assigned to you',
      format('%s%s — assigned by %s', coalesce((select c.name from public.customers c where c.id = v_lead.customer_id), v_lead.name),
             coalesce(' (' || v_lead.mobile || ')', ''), coalesce(v_by_name, 'someone')),
      v_lead.id);
  end if;

  return jsonb_build_object('lead_id', v_lead.id, 'assigned_to', p_assignee, 'previous', v_lead.assigned_to);
end;
$$;
revoke execute on function public.assign_lead(uuid, uuid, text) from public, anon;
grant execute on function public.assign_lead(uuid, uuid, text) to authenticated;

-- ── scope resolution shared by My Day and the menu badge ─────────────────
-- 'auto' = master: all, sales_admin: mine_unassigned. Others: all, mine,
-- unassigned, mine_unassigned, person (+ p_assignee). sales_admin may not use
-- 'all' or 'person' (no view of colleagues' leads).
create or replace function public._lead_resolve_scope(p_scope text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.user_role := public.current_role();
  v_scope text := coalesce(nullif(p_scope, ''), 'auto');
begin
  if v_scope not in ('auto', 'all', 'mine', 'unassigned', 'mine_unassigned', 'person') then
    raise exception 'invalid scope %', v_scope;
  end if;
  if v_scope = 'auto' then
    return case when v_role = 'master' then 'all' else 'mine_unassigned' end;
  end if;
  if v_role <> 'master' and v_scope in ('all', 'person') then
    raise exception 'not permitted: only master can view other people''s leads';
  end if;
  return v_scope;
end;
$$;
revoke execute on function public._lead_resolve_scope(text) from public, anon, authenticated;

-- ── list_followups (My Day): + scope / assignee, returns the assignee ────
drop function if exists public.list_followups(text, public.lead_status, text, public.lead_kind, boolean);

create or replace function public.list_followups(
  p_bucket text default 'all',
  p_stage public.lead_status default null,
  p_source text default null,
  p_kind public.lead_kind default null,
  p_stuck_only boolean default false,
  p_scope text default 'auto',
  p_assignee uuid default null
)
returns table (
  followup_id uuid,
  lead_id uuid,
  lead_name text,
  mobile text,
  source text,
  kind public.lead_kind,
  enquiry_type public.enquiry_type,
  lead_status public.lead_status,
  product_name text,
  due_at timestamptz,
  followup_type public.lead_followup_type,
  followup_note text,
  is_exact_time boolean,
  postpone_count integer,
  is_stuck boolean,
  bucket text,
  last_outcome_code text,
  last_outcome_label_en text,
  last_outcome_label_ta text,
  last_outcome_note text,
  last_outcome_at timestamptz,
  assignee_id uuid,
  assignee_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_stuck integer;
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  if p_bucket not in ('all', 'overdue', 'today', 'upcoming') then
    raise exception 'invalid bucket %', p_bucket;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;
  select coalesce(s.lead_stuck_postpones, 3) into v_stuck from public.settings s where s.org_id = v_org;
  v_stuck := coalesce(v_stuck, 3);

  return query
  select
    f.id, l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, l.kind, l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    f.due_at, f.type, f.note, f.is_exact_time, l.postpone_count, (l.postpone_count >= v_stuck),
    case
      when public._lead_ist_date(f.due_at) < v_today then 'overdue'
      when public._lead_ist_date(f.due_at) = v_today then 'today'
      when public._lead_ist_date(f.due_at) <= v_today + 7 then 'upcoming'
      else 'later'
    end,
    lo.code, lo.label_en, lo.label_ta, lo.note, lo.at,
    ap.id, ap.full_name
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.code, o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or l.kind = p_kind)
    and (not p_stuck_only or l.postpone_count >= v_stuck)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
    and (
      p_bucket = 'all'
      or (p_bucket = 'overdue' and public._lead_ist_date(f.due_at) < v_today)
      or (p_bucket = 'today' and public._lead_ist_date(f.due_at) = v_today)
      or (p_bucket = 'upcoming' and public._lead_ist_date(f.due_at) > v_today and public._lead_ist_date(f.due_at) <= v_today + 7)
    )
  order by f.due_at asc;
end;
$$;

-- ── followup_counts (menu badge): + scope; master also gets a per-person split ──
drop function if exists public.followup_counts();

create or replace function public.followup_counts(p_scope text default 'auto', p_assignee uuid default null)
returns jsonb
language plpgsql
stable
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

revoke execute on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean, text, uuid) from public, anon;
grant execute on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean, text, uuid) to authenticated;
revoke execute on function public.followup_counts(text, uuid) from public, anon;
grant execute on function public.followup_counts(text, uuid) to authenticated;

-- ── lead_timeline: same output, plus assignment events ───────────────────
create or replace function public.lead_timeline(p_lead_id uuid)
returns table (
  event_at timestamptz,
  kind text,
  author_id uuid,
  author_name text,
  author_kind text,
  title text,
  detail jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view the lead timeline';
  end if;
  if not exists (select 1 from public.leads where id = p_lead_id and org_id = v_org) then
    raise exception 'lead % not found', p_lead_id;
  end if;

  return query
  select * from (
    -- activities (outcomes, notes, stage changes, system/enquiry rows)
    select
      a.at,
      case
        when a.outcome_id is not null then 'outcome'
        when a.type = 'status_change' then 'stage_change'
        when a.type = 'note' then 'note'
        else 'activity'
      end,
      a.created_by, p.full_name,
      case when a.created_by is not null then 'user' when a.is_system then 'system' else 'before_upgrade' end,
      coalesce(o.label_en, a.type),
      jsonb_build_object(
        'activity_id', a.id, 'type', a.type, 'note', a.note, 'outcome_code', o.code,
        'outcome_label_en', o.label_en, 'outcome_label_ta', o.label_ta,
        'from_status', a.from_status, 'to_status', a.to_status
      )
    from public.lead_activities a
    left join public.lead_outcomes o on o.id = a.outcome_id
    left join public.profiles p on p.id = a.created_by
    where a.lead_id = p_lead_id and a.type <> 'quotation_created'

    union all
    -- follow-up set
    select f.created_at, 'followup_set', f.created_by, p.full_name,
      case when f.created_by is not null then 'user' else 'system' end,
      'followup_set',
      jsonb_build_object('followup_id', f.id, 'due_at', f.due_at, 'type', f.type, 'note', f.note,
        'source', f.source, 'is_exact_time', f.is_exact_time, 'replaces_followup_id', f.replaces_followup_id)
    from public.lead_followups f left join public.profiles p on p.id = f.created_by
    where f.lead_id = p_lead_id

    union all
    -- follow-up done
    select f.completed_at, 'followup_done', f.completed_by, p.full_name,
      case when f.completed_by is not null then 'user' else 'system' end,
      'followup_done',
      jsonb_build_object('followup_id', f.id, 'due_at', f.due_at, 'type', f.type, 'early', f.completed_at < f.due_at)
    from public.lead_followups f left join public.profiles p on p.id = f.completed_by
    where f.lead_id = p_lead_id and f.status = 'done'

    union all
    -- follow-up cancelled (rescheduled / lead won / lead lost)
    select f.cancelled_at, 'followup_cancelled', f.cancelled_by, p.full_name,
      case when f.cancelled_by is not null then 'user' else 'system' end,
      'followup_cancelled',
      jsonb_build_object('followup_id', f.id, 'due_at', f.due_at, 'type', f.type, 'cancel_reason', f.cancel_reason, 'reschedule_reason', f.reschedule_reason)
    from public.lead_followups f left join public.profiles p on p.id = f.cancelled_by
    where f.lead_id = p_lead_id and f.status = 'cancelled'

    union all
    -- assignment / reassignment / unassignment
    select g.created_at, 'assignment', g.assigned_by, p.full_name,
      case when g.assigned_by is not null then 'user' else 'system' end,
      'assignment',
      jsonb_build_object('from_user', g.from_user, 'from_name', pf.full_name, 'to_user', g.to_user, 'to_name', pt.full_name, 'reason', g.reason)
    from public.lead_assignments g
    left join public.profiles p on p.id = g.assigned_by
    left join public.profiles pf on pf.id = g.from_user
    left join public.profiles pt on pt.id = g.to_user
    where g.lead_id = p_lead_id

    union all
    -- quotations (author = whoever logged the matching quotation_created marker)
    select q.created_at, 'quotation', qa.created_by, p.full_name,
      case when qa.created_by is not null then 'user' when qa.id is not null and qa.is_system then 'system' else 'before_upgrade' end,
      'quotation',
      jsonb_build_object('quotation_id', q.id, 'total', q.total, 'status', q.status)
    from public.quotations q
    left join lateral (
      select a2.id, a2.created_by, a2.is_system from public.lead_activities a2
      where a2.lead_id = q.lead_id and a2.type = 'quotation_created'
      order by abs(extract(epoch from (a2.at - q.created_at))) limit 1
    ) qa on true
    left join public.profiles p on p.id = qa.created_by
    where q.lead_id = p_lead_id
  ) t
  order by 1 desc, 2 desc;
end;
$$;

-- ── scheduled notifications: assignee-aware + organisation filter ────────
-- Recipients are every active master / sales_admin of the organisation, and what
-- each one is told depends on what they can see (same rule as My Day):
--   * sales_admin: their own leads + effectively-unassigned leads
--   * master: the totals for the whole organisation, plus (only when something is
--     assigned) an unassigned count and a per-person split; the overdue-24h list
--     is the unassigned leads + the master's own, with per-person counts after it.
--   * exact-time callback reminders go to the assignee only; an unassigned lead
--     reminds every master and sales_admin (as before).
-- With nothing assigned every message is byte-for-byte what the previous version
-- sent. p_org_id limits the run to one organisation (tests use a throwaway org).
drop function if exists public.run_lead_followup_notifications(timestamptz);

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

          if v_n_today + v_n_overdue > 0 then
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

-- Only the scheduler (postgres via pg_cron) and service_role may run it.
revoke execute on function public.run_lead_followup_notifications(timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.run_lead_followup_notifications(timestamptz, uuid) to service_role;
