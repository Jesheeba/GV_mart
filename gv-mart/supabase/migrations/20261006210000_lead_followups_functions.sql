-- Lead follow-ups, outcomes and history — triggers + RPCs (Phase 1, commit 2b).
--
-- Everything here runs in Asia/Kolkata: "today", due dates and working-day
-- checks are computed with `at time zone 'Asia/Kolkata'`, never current_date.
--
-- All write RPCs are SECURITY DEFINER with an explicit is_sales_staff()
-- (master / sales_admin) + org check, because lead_followups and (from this
-- migration on) lead_activities have no client write policy — history is
-- append-only and every row records WHO via created_by / completed_by /
-- cancelled_by (auth.uid()). EXECUTE is revoked from public/anon: this
-- project auto-grants it on new functions.

-- ── IST / working-day helpers ────────────────────────────────────────────
create or replace function public._lead_ist_date(p_ts timestamptz)
returns date
language sql
immutable
as $$ select (p_ts at time zone 'Asia/Kolkata')::date $$;

-- An IST wall-clock date+time as a timestamptz.
create or replace function public._lead_ist_ts(p_date date, p_time time)
returns timestamptz
language sql
immutable
as $$ select ((p_date + p_time)::timestamp) at time zone 'Asia/Kolkata' $$;

create or replace function public._lead_is_working_day(p_org_id uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select extract(isodow from p_date)::smallint = any (
    coalesce((select s.lead_work_days from public.settings s where s.org_id = p_org_id), '{1,2,3,4,5,6}'::smallint[])
  )
$$;

-- First working day strictly after p_date.
create or replace function public.lead_next_working_day(p_org_id uuid, p_date date)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_d date := p_date;
  i int;
begin
  for i in 1..14 loop
    v_d := v_d + 1;
    if public._lead_is_working_day(p_org_id, v_d) then
      return v_d;
    end if;
  end loop;
  return p_date + 1;
end;
$$;

-- Due time of the automatic "Initial call": an hour from now if that lands
-- inside working hours; otherwise the next working-day opening slot
-- (work start + 30 min, i.e. 10:00 by default).
create or replace function public._lead_initial_due_at(p_org_id uuid, p_now timestamptz default now())
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start time;
  v_end time;
  v_cand timestamptz := date_trunc('minute', p_now + interval '1 hour');
  v_cand_date date;
  v_cand_time time;
  v_now_date date := public._lead_ist_date(p_now);
begin
  select s.lead_work_start, s.lead_work_end into v_start, v_end from public.settings s where s.org_id = p_org_id;
  v_start := coalesce(v_start, '09:30');
  v_end := coalesce(v_end, '19:00');

  v_cand_date := public._lead_ist_date(v_cand);
  v_cand_time := (v_cand at time zone 'Asia/Kolkata')::time;

  if public._lead_is_working_day(p_org_id, v_cand_date) and v_cand_time >= v_start and v_cand_time <= v_end then
    return v_cand;
  end if;

  -- Before opening on a working day -> that day's opening slot.
  if public._lead_is_working_day(p_org_id, v_now_date) and (p_now at time zone 'Asia/Kolkata')::time < v_start then
    return public._lead_ist_ts(v_now_date, v_start + interval '30 minutes');
  end if;

  return public._lead_ist_ts(public.lead_next_working_day(p_org_id, v_now_date), v_start + interval '30 minutes');
end;
$$;

revoke execute on function public._lead_ist_date(timestamptz) from public, anon;
revoke execute on function public._lead_ist_ts(date, time) from public, anon;
revoke execute on function public._lead_is_working_day(uuid, date) from public, anon, authenticated;
revoke execute on function public.lead_next_working_day(uuid, date) from public, anon;
revoke execute on function public._lead_initial_due_at(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public._lead_ist_date(timestamptz) to authenticated;
grant execute on function public._lead_ist_ts(date, time) to authenticated;
grant execute on function public.lead_next_working_day(uuid, date) to authenticated;

-- ── triggers ─────────────────────────────────────────────────────────────

-- Every stage change is recorded in the history with WHO changed it (works
-- for the stage buttons, log_lead_outcome, reopen_lead AND create_sale's
-- direct "won" update, which previously left no history at all).
create or replace function public._trg_lead_status_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.lead_activities (org_id, lead_id, type, note, at, from_status, to_status)
  values (
    new.org_id, new.id, 'status_change',
    case when new.status = 'lost' then new.lost_reason else new.status::text end,
    clock_timestamp(), old.status, new.status
  );
  return null;
end;
$$;

create trigger leads_status_history
  after update of status on public.leads
  for each row when (old.status is distinct from new.status)
  execute function public._trg_lead_status_history();

-- Won or Lost cancels any open follow-up (covers every path that closes a
-- lead, including create_sale). log_lead_outcome completes the task as 'done'
-- itself before closing, so this only sees tasks nobody contacted on.
create or replace function public._trg_lead_close_followups()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.lead_followups
    set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
        cancel_reason = case when new.status = 'won' then 'lead_won' else 'lead_lost' end
    where lead_id = new.id and status = 'open';
  return null;
end;
$$;

create trigger leads_close_followups
  after update of status on public.leads
  for each row when (new.status in ('won', 'lost') and old.status not in ('won', 'lost'))
  execute function public._trg_lead_close_followups();

-- Reopening a closed lead requires a new follow-up (reopen_lead creates it
-- first; a direct UPDATE that skips it is rejected).
create or replace function public._trg_lead_reopen_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.lead_followups where lead_id = new.id and status = 'open') then
    raise exception 'reopening a lead requires a new follow-up (use reopen_lead)';
  end if;
  return null;
end;
$$;

create trigger leads_reopen_guard
  after update of status on public.leads
  for each row when (old.status in ('won', 'lost') and new.status not in ('won', 'lost'))
  execute function public._trg_lead_reopen_guard();

-- Every new open lead (any source) gets an automatic "Initial call" task so
-- it shows up in My Day. Leads minted already won/lost get none.
create or replace function public._trg_lead_initial_followup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.lead_followups (org_id, lead_id, due_at, type, note, source)
  values (new.org_id, new.id, public._lead_initial_due_at(new.org_id), 'call', 'Initial call', 'initial_call');
  return null;
end;
$$;

create trigger leads_initial_followup
  after insert on public.leads
  for each row when (new.status not in ('won', 'lost'))
  execute function public._trg_lead_initial_followup();

-- leads.next_followup_at mirrors the single open task.
create or replace function public._trg_followup_sync_next()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead_id uuid := coalesce(new.lead_id, old.lead_id);
  v_next timestamptz;
begin
  select due_at into v_next from public.lead_followups where lead_id = v_lead_id and status = 'open';
  update public.leads set next_followup_at = v_next where id = v_lead_id and next_followup_at is distinct from v_next;
  return null;
end;
$$;

create trigger lead_followups_sync_next
  after insert or update or delete on public.lead_followups
  for each row execute function public._trg_followup_sync_next();

revoke execute on function public._trg_lead_status_history() from public, anon, authenticated;
revoke execute on function public._trg_lead_close_followups() from public, anon, authenticated;
revoke execute on function public._trg_lead_reopen_guard() from public, anon, authenticated;
revoke execute on function public._trg_lead_initial_followup() from public, anon, authenticated;
revoke execute on function public._trg_followup_sync_next() from public, anon, authenticated;

-- ── internal helpers for the RPCs ────────────────────────────────────────
create or replace function public._lead_lock(p_lead_id uuid)
returns public.leads
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can work leads';
  end if;
  select * into v_lead from public.leads where id = p_lead_id and org_id = public.current_org_id() for update;
  if not found then
    raise exception 'lead % not found', p_lead_id;
  end if;
  return v_lead;
end;
$$;

create or replace function public._lead_check_due(p_due timestamptz)
returns void
language plpgsql
as $$
begin
  if p_due is null then
    raise exception 'a follow-up date and time is required';
  end if;
  if p_due < now() - interval '5 minutes' then
    raise exception 'the follow-up time is in the past';
  end if;
  if p_due > now() + interval '2 years' then
    raise exception 'the follow-up time is too far ahead';
  end if;
end;
$$;

-- Sets the stage (and auto-creates the customer on Won, exactly as the old
-- update_lead_status did: only when the lead has no customer yet, matched by
-- mobile before creating a new one, flagged needs_setup).
create or replace function public._lead_apply_status(p_lead public.leads, p_status public.lead_status, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
begin
  if p_status = 'won' and p_lead.customer_id is null and p_lead.mobile is not null then
    select id into v_customer_id from public.customers where org_id = p_lead.org_id and mobile = p_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (p_lead.org_id, p_lead.name, p_lead.mobile, p_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  update public.leads
    set status = p_status,
        lost_reason = case when p_status = 'lost' then p_reason else null end,
        customer_id = coalesce(v_customer_id, customer_id)
    where id = p_lead.id;
end;
$$;

revoke execute on function public._lead_lock(uuid) from public, anon, authenticated;
revoke execute on function public._lead_check_due(timestamptz) from public, anon, authenticated;
revoke execute on function public._lead_apply_status(public.leads, public.lead_status, text) from public, anon, authenticated;

create or replace function public._lead_stage_rank(p_status public.lead_status)
returns int
language sql
immutable
as $$ select case p_status when 'new' then 1 when 'contacted' then 2 when 'quoted' then 3 else 99 end $$;
revoke execute on function public._lead_stage_rank(public.lead_status) from public, anon, authenticated;

-- ── log_lead_outcome ─────────────────────────────────────────────────────
-- ONE atomic call: insert the activity, close the open follow-up as done
-- (early contact included), apply the outcome's stage effect, maintain the
-- postpone count, and create the next follow-up (unless the outcome closes
-- the lead).
create or replace function public.log_lead_outcome(
  p_lead_id uuid,
  p_outcome_id uuid,
  p_note text default null,
  p_channel text default 'call',
  p_next_due_at timestamptz default null,
  p_next_type public.lead_followup_type default null,
  p_next_note text default null,
  p_next_is_exact boolean default false,
  p_lost_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_out public.lead_outcomes;
  v_activity_id uuid;
  v_followup_id uuid;
  v_closing boolean;
  v_reason text;
  v_postpone integer;
  v_open_id uuid;
begin
  v_lead := public._lead_lock(p_lead_id);

  if v_lead.status in ('won', 'lost') then
    raise exception 'this lead is already %; reopen it first', v_lead.status;
  end if;
  if p_channel not in ('call', 'whatsapp', 'visit', 'meeting') then
    raise exception 'invalid channel %', p_channel;
  end if;

  select * into v_out from public.lead_outcomes where id = p_outcome_id and org_id = v_lead.org_id and is_active;
  if not found then
    raise exception 'outcome % not found or inactive', p_outcome_id;
  end if;

  v_closing := v_out.stage_effect in ('won', 'lost');

  if v_out.stage_effect = 'lost' then
    v_reason := nullif(btrim(coalesce(p_lost_reason, v_out.lost_reason_hint, '')), '');
    if v_reason is null then
      raise exception 'a reason is required to mark a lead lost';
    end if;
  end if;

  if not v_closing and v_out.requires_followup then
    perform public._lead_check_due(p_next_due_at);
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note, at, outcome_id)
  values (v_lead.org_id, v_lead.id, p_channel, nullif(btrim(coalesce(p_note, '')), ''), clock_timestamp(), v_out.id)
  returning id into v_activity_id;

  -- The contact itself completes the open task, even if it was not due yet.
  update public.lead_followups
    set status = 'done', completed_by = auth.uid(), completed_at = clock_timestamp(), completing_activity_id = v_activity_id
    where lead_id = v_lead.id and status = 'open'
    returning id into v_open_id;

  v_postpone := case when v_out.counts_as_postpone then v_lead.postpone_count + 1 else 0 end;

  if v_out.stage_effect = 'won' then
    perform public._lead_apply_status(v_lead, 'won', null);
  elsif v_out.stage_effect = 'lost' then
    perform public._lead_apply_status(v_lead, 'lost', v_reason);
  elsif v_out.stage_effect is not null and public._lead_stage_rank(v_out.stage_effect) > public._lead_stage_rank(v_lead.status) then
    perform public._lead_apply_status(v_lead, v_out.stage_effect, null);
  end if;

  update public.leads set postpone_count = v_postpone where id = v_lead.id;

  if not v_closing and v_out.requires_followup then
    insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source, created_at)
    values (
      v_lead.org_id, v_lead.id, p_next_due_at, coalesce(p_next_type, v_out.default_followup_type),
      coalesce(p_next_is_exact, false) or v_out.followup_mode = 'exact_time',
      nullif(btrim(coalesce(p_next_note, '')), ''), 'outcome', clock_timestamp()
    )
    returning id into v_followup_id;
  end if;

  return jsonb_build_object(
    'activity_id', v_activity_id,
    'followup_id', v_followup_id,
    'completed_followup_id', v_open_id,
    'next_due_at', case when v_followup_id is not null then p_next_due_at end,
    'status', (select status from public.leads where id = v_lead.id),
    'postpone_count', v_postpone
  );
end;
$$;

-- ── reschedule_followup ──────────────────────────────────────────────────
-- Postponing WITHOUT contacting the customer. The old task is never edited
-- or deleted: it is cancelled (reason 'rescheduled' + the staff's reason) and
-- a new row replaces it. Pushing the task LATER counts as a postpone; pulling
-- it in earlier does not.
create or replace function public.reschedule_followup(
  p_lead_id uuid,
  p_new_due_at timestamptz,
  p_reason text,
  p_type public.lead_followup_type default null,
  p_note text default null,
  p_is_exact boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_old public.lead_followups;
  v_new_id uuid;
  v_postpone integer;
begin
  v_lead := public._lead_lock(p_lead_id);

  if v_lead.status in ('won', 'lost') then
    raise exception 'this lead is already %; reopen it first', v_lead.status;
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'a reason is required to reschedule a follow-up';
  end if;
  perform public._lead_check_due(p_new_due_at);

  select * into v_old from public.lead_followups where lead_id = v_lead.id and status = 'open';
  if not found then
    raise exception 'this lead has no open follow-up to reschedule';
  end if;

  update public.lead_followups
    set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = clock_timestamp(),
        cancel_reason = 'rescheduled', reschedule_reason = btrim(p_reason)
    where id = v_old.id;

  insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source, replaces_followup_id, created_at)
  values (
    v_lead.org_id, v_lead.id, p_new_due_at, coalesce(p_type, v_old.type), coalesce(p_is_exact, false),
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), v_old.note), 'reschedule', v_old.id, clock_timestamp()
  )
  returning id into v_new_id;

  v_postpone := v_lead.postpone_count + case when p_new_due_at > v_old.due_at then 1 else 0 end;
  update public.leads set postpone_count = v_postpone where id = v_lead.id;

  return jsonb_build_object('followup_id', v_new_id, 'cancelled_followup_id', v_old.id, 'next_due_at', p_new_due_at, 'postpone_count', v_postpone);
end;
$$;

-- ── set_lead_followup ────────────────────────────────────────────────────
-- Creates a task for an open lead that has none (the "No follow-up" fix).
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

-- ── reopen_lead ──────────────────────────────────────────────────────────
create or replace function public.reopen_lead(
  p_lead_id uuid,
  p_next_due_at timestamptz,
  p_type public.lead_followup_type default 'call',
  p_note text default null,
  p_is_exact boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_id uuid;
begin
  v_lead := public._lead_lock(p_lead_id);
  if v_lead.status not in ('won', 'lost') then
    raise exception 'only a won or lost lead can be reopened';
  end if;
  perform public._lead_check_due(p_next_due_at);

  -- Follow-up first: the reopen guard trigger requires one to exist.
  insert into public.lead_followups (org_id, lead_id, due_at, type, is_exact_time, note, source)
  values (v_lead.org_id, v_lead.id, p_next_due_at, coalesce(p_type, 'call'), coalesce(p_is_exact, false), nullif(btrim(coalesce(p_note, '')), ''), 'reopen')
  returning id into v_id;

  update public.leads set status = 'contacted', lost_reason = null, postpone_count = 0 where id = v_lead.id;

  return jsonb_build_object('followup_id', v_id, 'next_due_at', p_next_due_at, 'status', 'contacted');
end;
$$;

-- ── add_lead_note ────────────────────────────────────────────────────────
-- A plain note on an open OR closed lead. Does not touch the follow-up, the
-- stage or postpone_count. (p_type 'quotation_created' is used by the
-- quotation form to leave a timeline marker with its author.)
create or replace function public.add_lead_note(p_lead_id uuid, p_note text, p_type text default 'note')
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
  if p_type not in ('note', 'quotation_created') then
    raise exception 'invalid note type %', p_type;
  end if;
  if p_type = 'note' and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'a note cannot be empty';
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note, at)
  values (v_lead.org_id, v_lead.id, p_type, nullif(btrim(coalesce(p_note, '')), ''), clock_timestamp())
  returning id into v_id;
  return v_id;
end;
$$;

-- ── update_lead_status (stage buttons) ───────────────────────────────────
-- Redefined from 20260916091000. Now SECURITY DEFINER (the history row is
-- written by the leads_status_history trigger, the open task is cancelled by
-- leads_close_followups). A closed lead can no longer be moved straight back
-- to an open stage — that needs reopen_lead so a new follow-up is set.
drop function if exists public.update_lead_status(uuid, public.lead_status, text);

create or replace function public.update_lead_status(p_lead_id uuid, p_status public.lead_status, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
begin
  v_lead := public._lead_lock(p_lead_id);

  if p_status = 'lost' and trim(coalesce(p_reason, '')) = '' then
    raise exception 'update_lead_status: a reason is required to mark a lead lost';
  end if;
  if v_lead.status in ('won', 'lost') and p_status not in ('won', 'lost') then
    raise exception 'update_lead_status: reopen this lead with reopen_lead so a new follow-up is set';
  end if;
  if v_lead.status = p_status and p_status <> 'lost' then
    return;
  end if;

  perform public._lead_apply_status(v_lead, p_status, nullif(btrim(coalesce(p_reason, '')), ''));
end;
$$;

-- ── replace log_lead_activity ────────────────────────────────────────────
drop function if exists public.log_lead_activity(uuid, text, text);
drop policy if exists lead_activities_insert_sales on public.lead_activities;

-- ── list_followups (My Day) ──────────────────────────────────────────────
-- Buckets use the IST calendar day: overdue = due on an earlier IST day,
-- today = due today (a missed 10:00 call stays in Today, flagged red by the
-- UI), upcoming = the next 7 IST days.
create or replace function public.list_followups(
  p_bucket text default 'all',
  p_stage public.lead_status default null,
  p_source text default null,
  p_kind public.lead_kind default null,
  p_stuck_only boolean default false
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
  last_outcome_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_today date := public._lead_ist_date(now());
  v_stuck integer;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  if p_bucket not in ('all', 'overdue', 'today', 'upcoming') then
    raise exception 'invalid bucket %', p_bucket;
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
    lo.code, lo.label_en, lo.label_ta, lo.note, lo.at
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.customers c on c.id = l.customer_id
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
      p_bucket = 'all'
      or (p_bucket = 'overdue' and public._lead_ist_date(f.due_at) < v_today)
      or (p_bucket = 'today' and public._lead_ist_date(f.due_at) = v_today)
      or (p_bucket = 'upcoming' and public._lead_ist_date(f.due_at) > v_today and public._lead_ist_date(f.due_at) <= v_today + 7)
    )
  order by f.due_at asc;
end;
$$;

-- Menu badge: today + overdue (IST days).
create or replace function public.followup_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_today date := public._lead_ist_date(now());
  v_overdue int;
  v_today_n int;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  select
    count(*) filter (where public._lead_ist_date(f.due_at) < v_today),
    count(*) filter (where public._lead_ist_date(f.due_at) = v_today)
  into v_overdue, v_today_n
  from public.lead_followups f join public.leads l on l.id = f.lead_id
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost');
  return jsonb_build_object('overdue', v_overdue, 'today', v_today_n, 'total', v_overdue + v_today_n);
end;
$$;

-- ── lead_timeline ────────────────────────────────────────────────────────
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

-- ── grants ───────────────────────────────────────────────────────────────
revoke execute on function public.log_lead_outcome(uuid, uuid, text, text, timestamptz, public.lead_followup_type, text, boolean, text) from public, anon;
revoke execute on function public.reschedule_followup(uuid, timestamptz, text, public.lead_followup_type, text, boolean) from public, anon;
revoke execute on function public.set_lead_followup(uuid, timestamptz, public.lead_followup_type, text, boolean) from public, anon;
revoke execute on function public.reopen_lead(uuid, timestamptz, public.lead_followup_type, text, boolean) from public, anon;
revoke execute on function public.add_lead_note(uuid, text, text) from public, anon;
revoke execute on function public.update_lead_status(uuid, public.lead_status, text) from public, anon;
revoke execute on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean) from public, anon;
revoke execute on function public.followup_counts() from public, anon;
revoke execute on function public.lead_timeline(uuid) from public, anon;

grant execute on function public.log_lead_outcome(uuid, uuid, text, text, timestamptz, public.lead_followup_type, text, boolean, text) to authenticated;
grant execute on function public.reschedule_followup(uuid, timestamptz, text, public.lead_followup_type, text, boolean) to authenticated;
grant execute on function public.set_lead_followup(uuid, timestamptz, public.lead_followup_type, text, boolean) to authenticated;
grant execute on function public.reopen_lead(uuid, timestamptz, public.lead_followup_type, text, boolean) to authenticated;
grant execute on function public.add_lead_note(uuid, text, text) to authenticated;
grant execute on function public.update_lead_status(uuid, public.lead_status, text) to authenticated;
grant execute on function public.list_followups(text, public.lead_status, text, public.lead_kind, boolean) to authenticated;
grant execute on function public.followup_counts() to authenticated;
grant execute on function public.lead_timeline(uuid) to authenticated;
