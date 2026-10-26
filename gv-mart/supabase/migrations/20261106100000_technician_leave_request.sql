-- Technician leave request in advance (KPI-protected). Spec: FEATURE_TECHNICIAN_LEAVE_REQUEST.md.
--
-- WHY A NEW TABLE, NOT AN EXTENSION OF technician_availability (owner decision 2026-10-26):
-- The only existing "leave record" in this schema is public.technician_availability
-- (20260721090000_technician_assignment_phase1_data.sql): one row per (technician_id, date),
-- status in ('working','leave'), unique(technician_id, date). It has no request/approval/range/
-- notice-day concept, and is read today by the assignment hard-filter and (on the unmerged branch
-- feat/amc-release-path, migration 20261025100000, NOT applied here) the zz_amc_release_on_leave
-- trigger — both test status = 'leave' only. A request spans a date range and must exist (as
-- 'pending') before it is a real leave day, which the existing unique(technician_id,date) +
-- status check('working','leave') cannot represent without weakening a constraint two other
-- features already depend on. So: technician_leave_requests is the new request/approval table;
-- approving one materialises plain 'leave' rows into technician_availability (same shape admin's
-- own direct-entry path already writes via techniciansAdmin.ts upsertTechnicianAvailability), so
-- the assignment filter and the (if/when merged) AMC trigger pick it up with zero changes to them.
-- technician_availability itself is only extended (two nullable columns), never its existing
-- unique constraint.
--
-- AMC NOTE: zz_amc_release_on_leave does not exist in this branch's ancestry (20261025100000 is
-- unapplied, on feat/amc-release-path only). Until that branch is merged and applied, approving a
-- leave request still writes status='leave' into technician_availability (so the assignment
-- engine stops offering the technician for those future dates), but an AMC visit already assigned
-- to them on a leave day is NOT taken back automatically — exactly as it is today for admin-direct
-- leave entry. Once 20261025100000 lands, this feature needs no further change: the trigger fires
-- on "update of status" on technician_availability, which is exactly what decide_technician_leave
-- below does on approval.
--
-- READING OF §2.1's notice-day bullet: the manual test script (§7) submits a request "starting
-- tomorrow" and expects it to be accepted and shown as "Late (KPI not protected)", which only makes
-- sense if the database accepts a short-notice request rather than rejecting it outright. So
-- leave_notice_days is enforced as a hard floor only for the single sanity rule "a request cannot
-- start today or in the past" (any technician-submitted leave is for a future date); the full
-- configurable notice window only ever decides the `protected` flag, recomputed at approval time
-- against the live setting value. Overlap and max-length ARE hard database constraints.

-- ── setting ──────────────────────────────────────────────────────────────────────────────────
alter table public.settings
  add column if not exists leave_notice_days integer not null default 1
    check (leave_notice_days >= 0);

-- ── the request table ───────────────────────────────────────────────────────────────────────
create extension if not exists btree_gist;

create table public.technician_leave_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text check (reason is null or char_length(reason) <= 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled', 'revoked')),
  protected boolean not null default false,
  requested_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 500),
  updated_at timestamptz not null default now(),
  period daterange generated always as (daterange(start_date, end_date, '[]')) stored,
  constraint technician_leave_requests_dates_ok check (end_date >= start_date),
  constraint technician_leave_requests_max_30_days check (end_date - start_date <= 29),
  -- a technician's own pending/approved requests can never overlap (DB-enforced, not only the screen)
  constraint technician_leave_requests_no_overlap
    exclude using gist (technician_id with =, period with &&) where (status in ('pending', 'approved'))
);

create index technician_leave_requests_org_status_idx on public.technician_leave_requests (org_id, status);
create index technician_leave_requests_technician_idx on public.technician_leave_requests (technician_id);

alter table public.technician_leave_requests enable row level security;

create policy technician_leave_requests_own_select on public.technician_leave_requests
  for select
  using (technician_id = public.current_technician_id());

create policy technician_leave_requests_staff_select on public.technician_leave_requests
  for select
  using (org_id = public.current_org_id() and public.is_ops_staff());

-- all writes go through the SECURITY DEFINER functions below; no insert/update/delete grant to
-- authenticated at all (there is deliberately no RLS write policy for that reason).
grant select on public.technician_leave_requests to authenticated;

create trigger set_updated_at before update on public.technician_leave_requests
  for each row execute function public.set_updated_at();

-- ── link columns on the existing calendar table (per owner decision: extend, don't touch its
--    existing unique(technician_id, date) constraint) ───────────────────────────────────────────
alter table public.technician_availability
  add column if not exists leave_request_id uuid references public.technician_leave_requests (id) on delete set null,
  add column if not exists protected boolean not null default false;

-- ── the one place "is this day protected" is computed (used both at decision time and by the
--    KPI exclusion below; never trust a client-supplied flag) ─────────────────────────────────
create or replace function public._leave_request_is_protected(p_created_at timestamptz, p_start_date date, p_notice_days integer)
returns boolean
language sql
immutable
as $$
  select (p_created_at at time zone 'Asia/Kolkata')::date <= (p_start_date - p_notice_days)
$$;
revoke all on function public._leave_request_is_protected(timestamptz, date, integer) from public, anon, authenticated;

-- ── submit a request (technician only) ──────────────────────────────────────────────────────
create or replace function public.request_technician_leave(p_start_date date, p_end_date date, p_reason text default null)
returns public.technician_leave_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_technician_id uuid := public.current_technician_id();
  v_org_id uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_row public.technician_leave_requests;
begin
  if v_technician_id is null then
    raise exception 'request_technician_leave: caller is not a technician';
  end if;
  select org_id into v_org_id from public.technicians where id = v_technician_id;

  if p_start_date is null or p_end_date is null then
    raise exception 'request_technician_leave: start and end date are required';
  end if;
  if p_start_date <= v_today then
    raise exception 'request_technician_leave: start date must be in the future';
  end if;
  if p_end_date < p_start_date then
    raise exception 'request_technician_leave: end date cannot be before start date';
  end if;
  if (p_end_date - p_start_date) > 29 then
    raise exception 'request_technician_leave: a single request cannot exceed 30 days';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is not null and char_length(p_reason) > 500 then
    raise exception 'request_technician_leave: reason cannot exceed 500 characters';
  end if;

  insert into public.technician_leave_requests (org_id, technician_id, start_date, end_date, reason, requested_by)
  values (v_org_id, v_technician_id, p_start_date, p_end_date, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid())
  returning * into v_row;
  -- a violated technician_leave_requests_no_overlap EXCLUDE constraint raises here with its own
  -- Postgres error; the front end shows it as "overlaps an existing request"

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  select v_org_id, r, 'technician_leave_requested', 'New leave request',
    format('A technician requested leave from %s to %s.', to_char(p_start_date, 'DD Mon YYYY'), to_char(p_end_date, 'DD Mon YYYY')),
    v_row.id
  from unnest(array['master', 'operation_admin']::user_role[]) as r;

  return v_row;
end;
$$;
revoke all on function public.request_technician_leave(date, date, text) from public, anon, authenticated;
grant execute on function public.request_technician_leave(date, date, text) to authenticated;

-- ── technician cancels their own request ────────────────────────────────────────────────────
create or replace function public.cancel_technician_leave(p_request_id uuid)
returns public.technician_leave_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_technician_id uuid := public.current_technician_id();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_row public.technician_leave_requests;
begin
  if v_technician_id is null then
    raise exception 'cancel_technician_leave: caller is not a technician';
  end if;

  select * into v_row from public.technician_leave_requests where id = p_request_id for update;
  if v_row.id is null then
    raise exception 'cancel_technician_leave: request % not found', p_request_id;
  end if;
  if v_row.technician_id is distinct from v_technician_id then
    raise exception 'cancel_technician_leave: not your request';
  end if;
  if not (v_row.status = 'pending' or (v_row.status = 'approved' and v_row.start_date > v_today)) then
    raise exception 'cancel_technician_leave: this request can no longer be cancelled';
  end if;

  if v_row.status = 'approved' then
    delete from public.technician_availability where leave_request_id = p_request_id and status = 'leave';
  end if;

  update public.technician_leave_requests
     set status = 'cancelled', decided_by = auth.uid(), decided_at = now()
   where id = p_request_id
   returning * into v_row;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_row.org_id, p.id, 'technician_leave_cancelled', 'Leave request cancelled',
    format('Leave from %s to %s was cancelled.', to_char(v_row.start_date, 'DD Mon YYYY'), to_char(v_row.end_date, 'DD Mon YYYY')), v_row.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_row.technician_id;

  return v_row;
end;
$$;
revoke all on function public.cancel_technician_leave(uuid) from public, anon, authenticated;
grant execute on function public.cancel_technician_leave(uuid) to authenticated;

-- ── master / operation_admin decide (approve / reject / revoke) ────────────────────────────
create or replace function public.decide_technician_leave(p_request_id uuid, p_decision text, p_decision_note text default null)
returns public.technician_leave_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.technician_leave_requests;
  v_notice_days integer;
  v_protected boolean;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_conflicts text;
  v_profile_id uuid;
begin
  if not public.is_ops_staff() then
    raise exception 'decide_technician_leave: master or operation_admin role required';
  end if;
  if p_decision not in ('approved', 'rejected', 'revoked') then
    raise exception 'decide_technician_leave: invalid decision %', p_decision;
  end if;

  select * into v_row from public.technician_leave_requests where id = p_request_id for update;
  if v_row.id is null then
    raise exception 'decide_technician_leave: request % not found', p_request_id;
  end if;
  if v_row.org_id is distinct from public.current_org_id() then
    raise exception 'decide_technician_leave: org mismatch';
  end if;

  if p_decision in ('approved', 'rejected') and v_row.status <> 'pending' then
    raise exception 'decide_technician_leave: only a pending request can be approved or rejected';
  end if;
  if p_decision = 'revoked' and not (v_row.status = 'approved' and v_row.start_date > v_today) then
    raise exception 'decide_technician_leave: only an approved, not-yet-started request can be revoked';
  end if;
  if p_decision in ('rejected', 'revoked') and nullif(btrim(coalesce(p_decision_note, '')), '') is null then
    raise exception 'decide_technician_leave: a decision note is required';
  end if;

  if p_decision = 'approved' then
    select leave_notice_days into v_notice_days from public.settings where org_id = v_row.org_id;
    v_protected := public._leave_request_is_protected(v_row.created_at, v_row.start_date, coalesce(v_notice_days, 1));

    select string_agg(to_char(d, 'DD Mon YYYY'), ', ')
      into v_conflicts
      from generate_series(v_row.start_date, v_row.end_date, interval '1 day') g(d)
      join public.technician_availability ta
        on ta.technician_id = v_row.technician_id and ta.date = g.d::date and ta.status <> 'leave';
    if v_conflicts is not null then
      raise exception 'decide_technician_leave: % already has a non-leave availability entry on %', v_row.technician_id, v_conflicts;
    end if;

    insert into public.technician_availability (org_id, technician_id, date, status, leave_request_id, protected)
    select v_row.org_id, v_row.technician_id, g.d::date, 'leave', p_request_id, v_protected
    from generate_series(v_row.start_date, v_row.end_date, interval '1 day') g(d)
    on conflict (technician_id, date) do update
      set leave_request_id = p_request_id, protected = v_protected
      where public.technician_availability.status = 'leave';

    update public.technician_leave_requests
       set status = 'approved', protected = v_protected, decided_by = auth.uid(), decided_at = now(), decision_note = p_decision_note
     where id = p_request_id
     returning * into v_row;
  elsif p_decision = 'revoked' then
    delete from public.technician_availability where leave_request_id = p_request_id and status = 'leave';
    update public.technician_leave_requests
       set status = 'revoked', decided_by = auth.uid(), decided_at = now(), decision_note = p_decision_note
     where id = p_request_id
     returning * into v_row;
  else
    update public.technician_leave_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_decision_note
     where id = p_request_id
     returning * into v_row;
  end if;

  select p.id into v_profile_id from public.technicians t join public.profiles p on p.id = t.profile_id where t.id = v_row.technician_id;
  if v_profile_id is not null then
    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (v_row.org_id, v_profile_id, 'technician_leave_' || v_row.status,
      case v_row.status when 'approved' then 'Leave approved' when 'rejected' then 'Leave rejected' else 'Leave revoked' end,
      format('Leave from %s to %s: %s%s', to_char(v_row.start_date, 'DD Mon YYYY'), to_char(v_row.end_date, 'DD Mon YYYY'),
             v_row.status, case when p_decision_note is not null then ' — ' || p_decision_note else '' end),
      v_row.id);
  end if;

  return v_row;
end;
$$;
revoke all on function public.decide_technician_leave(uuid, text, text) from public, anon, authenticated;
grant execute on function public.decide_technician_leave(uuid, text, text) to authenticated;

-- ── read-only admin helper: assigned visits on the requested days, for the approve-time warning ──
create or replace function public.technician_assigned_visits_in_range(p_technician_id uuid, p_start_date date, p_end_date date)
returns table (appointment_id uuid, ticket_id uuid, scheduled_at timestamptz, customer_name text, name_of_complaint text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_ops_staff() then
    raise exception 'technician_assigned_visits_in_range: master or operation_admin role required';
  end if;
  return query
  select a.id, a.ticket_id, a.scheduled_at, c.name, st.name_of_complaint
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  left join public.customers c on c.id = st.customer_id
  where st.org_id = public.current_org_id()
    and a.technician_id = p_technician_id
    and a.status = 'scheduled'
    and a.scheduled_at is not null
    and (a.scheduled_at at time zone 'Asia/Kolkata')::date between p_start_date and p_end_date
  order by a.scheduled_at;
end;
$$;
revoke all on function public.technician_assigned_visits_in_range(uuid, date, date) from public, anon, authenticated;
grant execute on function public.technician_assigned_visits_in_range(uuid, date, date) to authenticated;

-- ── KPI exclusion: the shared count of protected leave days in a period, read by reward_candidates
--    below and callable by the front end to show "N day(s) excluded" on the technician table.
--    Counts only ORGANISATION WORKING DAYS within [p_from, p_to] -- the same weekly pattern
--    reward_candidates' org_days uses (settings.lead_work_days, ISO day-of-week 1=Mon..7=Sun; the
--    same column the lead-followup and AMC/rental "roll to next working day" logic already reads,
--    reused here rather than inventing a second org-working-day setting). A leave day that falls
--    on a day the org doesn't operate (e.g. Sunday) was never an "expected working day" to begin
--    with, so it is not protected leave either -- it must not inflate the exclusion. This schema
--    has no separate holiday calendar, so a gazetted holiday on an otherwise-working weekday is
--    NOT excluded here; that is a real gap, not something silently pretended to be handled. ──────
create or replace function public.technician_protected_leave_days(p_org_id uuid, p_technician_id uuid, p_from date, p_to date)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_work_days smallint[];
  v_n integer;
begin
  -- is_staff(), not is_ops_staff(): this is also called internally by reward_candidates(), which
  -- any staff role (incl. sales_admin) may invoke.
  if not (public.is_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_protected_leave_days: access denied';
  end if;

  select coalesce(s.lead_work_days, '{1,2,3,4,5,6}'::smallint[]) into v_work_days
    from public.settings s where s.org_id = p_org_id;
  v_work_days := coalesce(v_work_days, '{1,2,3,4,5,6}'::smallint[]);

  select count(*) into v_n
  from (
    select generate_series(
             lower(r.period * daterange(p_from, p_to, '[]')),
             upper(r.period * daterange(p_from, p_to, '[]')) - 1,
             interval '1 day'
           )::date as d
    from public.technician_leave_requests r
    where r.org_id = p_org_id
      and r.technician_id = p_technician_id
      and r.status = 'approved'
      and r.protected
      and r.period && daterange(p_from, p_to, '[]')
  ) days
  where extract(isodow from d)::smallint = any (v_work_days);

  return coalesce(v_n, 0);
end;
$$;
revoke all on function public.technician_protected_leave_days(uuid, uuid, date, date) from public, anon, authenticated;
grant execute on function public.technician_protected_leave_days(uuid, uuid, date, date) to authenticated;

-- ── KPI wiring: reward_candidates' "expected working days" must not penalise protected leave.
--    Same signature as the live function (20261016110000_test_customer_flag.sql:896). Changes:
--      1. org_days is redefined from the org's weekly working-day pattern (settings.lead_work_days)
--         instead of "any date anyone has an attendance row for". The old definition let a single
--         technician's own anomalous attendance on a non-working day (e.g. unscheduled Sunday
--         overtime) silently make that day "expected" for everyone else too, AND let that same
--         extra day substitute for a missing real working day in that technician's own count
--         (attendance_agg counted raw distinct dates, not distinct working dates). Both are closed
--         below. The review/revenue/referral CTEs have nothing to do with leave and are untouched.
--      2. attendance_agg now joins to org_days, so only attendance on an organisation working day
--         counts toward days_present.
--      3. protected_agg (new) adds technician_protected_leave_days(), which itself now only counts
--         protected-leave days that are organisation working days (see that function's own header).
--      4. attendance_agg's exact-equality `having` becomes a `>=` comparison against days_present +
--         protected days, in attendance_eligible. ──────────────────────────────────────────────
create or replace function public.reward_candidates(p_org_id uuid, p_period date)
 returns table(category reward_category, technician_id uuid, metric numeric)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_period_end date := (date_trunc('month', p_period) + interval '1 month' - interval '1 day')::date;
  v_late_cutoff time;
begin
  if not public.is_staff() then
    raise exception 'reward_candidates: staff role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'reward_candidates: org mismatch';
  end if;

  select late_cutoff into v_late_cutoff from public.settings where org_id = p_org_id;
  v_late_cutoff := coalesce(v_late_cutoff, '09:15:00'::time);

  return query
  with org_days as (
    -- "Expected working days" = the org's configured weekly working-day pattern
    -- (settings.lead_work_days, ISO day-of-week 1=Mon..7=Sun — the same column the
    -- lead-followup and AMC/rental "roll to next working day" logic already reads,
    -- reused here rather than inventing a second org-working-day setting),
    -- intersected with this month's calendar dates. Independent of whether anyone
    -- actually has an attendance row that day (see header note 1 above). No
    -- separate holiday calendar exists in this schema, so a gazetted holiday that
    -- falls on an otherwise-working weekday is not excluded here.
    select d::date as date
    from generate_series(v_period, v_period_end, interval '1 day') d
    where extract(isodow from d)::smallint = any (
      coalesce((select s.lead_work_days from public.settings s where s.org_id = p_org_id), '{1,2,3,4,5,6}'::smallint[])
    )
  ),
  org_day_count as (
    select count(*) as n from org_days
  ),
  late_hours_agg as (
    -- Same "hours late" derivation as technician_late_hours() (hr_functions.sql),
    -- inlined here since this runs as one set-based query across all technicians.
    select a.technician_id,
      coalesce(sum(
        greatest(0, extract(epoch from ((a.check_in_at at time zone 'Asia/Kolkata')::time - v_late_cutoff)) / 3600.0)
      ), 0) as late_hours
    from public.attendance a
    where a.org_id = p_org_id
      and a.is_late = true
      and a.check_in_at is not null
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
    group by a.technician_id
  ),
  -- NEW: protected leave (requested in advance per leave_notice_days, approved) excludes that many
  -- days from the "must be present every org-operating day" requirement below.
  protected_agg as (
    select t.id as technician_id, public.technician_protected_leave_days(p_org_id, t.id, v_period, v_period_end) as days_protected
    from public.technicians t
    where t.org_id = p_org_id
  ),
  attendance_agg as (
    -- Full attendance: a row on every organisation working day this month. Joined to org_days
    -- (not just date-range-filtered) so attendance on a non-working day (e.g. unscheduled Sunday
    -- overtime) is never counted — it must not be able to substitute for a missing working day.
    select a.technician_id, count(distinct a.date) as days_present
    from public.attendance a
    join org_days od on od.date = a.date
    where a.org_id = p_org_id
    group by a.technician_id
  ),
  attendance_eligible as (
    select aa.technician_id, coalesce(lh.late_hours, 0) as late_hours
    from attendance_agg aa
    left join late_hours_agg lh on lh.technician_id = aa.technician_id
    left join protected_agg pa on pa.technician_id = aa.technician_id
    where aa.days_present + coalesce(pa.days_protected, 0) >= (select n from org_day_count)
      and coalesce(lh.late_hours, 0) <= 3
  ),
  review_agg as (
    select v.technician_id, count(*) as review_count
    from public.ratings r
    join public.service_visits v on v.id = r.visit_id
    where v.org_id = p_org_id
      and not public._visit_is_test(v.id)
      and r.created_at >= v_period
      and r.created_at < v_period + interval '1 month'
    group by v.technician_id
  ),
  revenue_agg as (
    select t.id as technician_id,
      public.technician_attributed_revenue(p_org_id, t.id, v_period)
        + public.technician_attributed_sales(p_org_id, t.id, v_period) as revenue
    from public.technicians t
    where t.org_id = p_org_id and t.is_active
  ),
  referral_agg as (
    select t.id as technician_id,
      public.technician_finder_conversions(p_org_id, t.id, v_period) as referrals
    from public.technicians t
    where t.org_id = p_org_id and t.is_active
  )
  select 'attendance'::reward_category, ae.technician_id, ae.late_hours::numeric
  from attendance_eligible ae
  where (select n from org_day_count) > 0
    and ae.late_hours = (select min(late_hours) from attendance_eligible)
  union all
  select 'highest_review'::reward_category, ra.technician_id, ra.review_count::numeric
  from review_agg ra
  where ra.review_count >= 51
    and ra.review_count = (select max(review_count) from review_agg where review_count >= 51)
  union all
  select 'highest_revenue'::reward_category, rv.technician_id, rv.revenue::numeric
  from revenue_agg rv
  where rv.revenue >= 150000
    and rv.revenue = (select max(revenue) from revenue_agg where revenue >= 150000)
  union all
  select 'highest_referral'::reward_category, rf.technician_id, rf.referrals::numeric
  from referral_agg rf
  where rf.referrals >= 20
    and rf.referrals = (select max(referrals) from referral_agg where referrals >= 20);
end;
$function$;

notify pgrst, 'reload schema';
