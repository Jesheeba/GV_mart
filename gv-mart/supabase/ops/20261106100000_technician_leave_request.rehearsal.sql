-- Rehearsal wrapper for 20261106100000_technician_leave_request.sql.
-- One DO block. Refuses before 18:00 IST. Hashes with encode(sha256(convert_to(v_text,'UTF8')),
-- 'hex') -- NOT a text::bytea cast, which goes through byteain and can reinterpret backslash
-- escapes in the text, changing the hash out from under a byte-identical file. Recomputes sha256
-- of the embedded migration and test text and compares against the pinned hashes below (must
-- match the committed .sql files exactly, LF line endings, verified 0 CR bytes). Before touching
-- anything, verifies the recorded 'live' body of reward_candidates (the function this migration
-- redefines) still matches what is actually live, by recreating that recorded body in a
-- sub-block and comparing md5(pg_get_functiondef(...)), then rolling that sub-block back -- a
-- mismatch means reward_candidates changed since 20261016110000 and this migration's
-- create-or-replace would silently clobber an assumption we never verified, so it refuses. Also
-- takes a relative fingerprint of a real (non-__TEST_) organisation's technician_availability
-- and technician_leave_requests data before running anything, and compares it again at the very
-- end. Runs the migration and test via EXECUTE. No top-level BEGIN/COMMIT/SAVEPOINT/ROLLBACK: the
-- block always ends in an unconditional RAISE EXCEPTION, so the enclosing statement aborts and
-- nothing persists regardless of outcome.
do $w$
declare
  v_migration text := $MIGRATION_BODY$-- Technician leave request in advance (KPI-protected). Spec: FEATURE_TECHNICIAN_LEAVE_REQUEST.md.
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
$MIGRATION_BODY$;
  v_test text := $TEST_BODY$-- Rolled-back check for 20261106100000_technician_leave_request.sql. Uses its own throwaway
-- organisation so this test's requests/availability/attendance rows never interact with another
-- org's data. Run through the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
--
-- AMC leave trigger (zz_amc_release_on_leave): migration 20261025100000 is NOT applied in this
-- branch's ancestry (it lives on the unmerged feat/amc-release-path only — see the migration's
-- header note). There is nothing to test here; this is stated, not silently skipped.
--
-- TEST NOTE for when 20261025100000 is applied (add this case then, it cannot run today):
-- decide_technician_leave's approval writes technician_availability per day in the range as an
-- upsert: a day with NO existing row is a plain INSERT (status='leave') — the trigger's "after
-- insert or update of status, date ... when (new.status='leave')" fires unconditionally on
-- INSERT, so this day WILL release any already-assigned AMC visit. A day that already carried a
-- pre-existing 'leave' row (only possible if an admin had created it directly first — any other
-- pre-existing status aborts the whole approval before any write) instead takes the ON CONFLICT
-- DO UPDATE branch, whose SET list is `leave_request_id, protected` only — it never touches
-- `status` or `date`, so Postgres' "UPDATE OF status, date" trigger scoping means the trigger
-- will NOT re-fire for that day (correctly: the day was already 'leave', nothing changed for the
-- release path to react to). Once that migration is applied, assert: inserting a NEW leave day
-- for a technician with a future assigned AMC visit releases it (trigger fired); approving a
-- request whose day was already an admin-direct 'leave' row does not re-run the release logic a
-- second time for that day.
--
-- KPI TEST DESIGN: the org's settings.lead_work_days is set to {1} (Monday only) for this test
-- org, so "organisation working days" in March 2026 are exactly the five Mondays: 2, 9, 16, 23,
-- 30. This keeps the fixtures small while exercising the real weekly-pattern logic (not a
-- calendar-month's worth of working days). All KPI cases use these fixed 2026-03 dates so they
-- do not depend on when the rehearsal actually runs.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1id uuid; v_t2 uuid; v_t2id uuid; v_ctrl uuid; v_ctrlid uuid;
  v_sun uuid; v_sunid uuid; v_extra uuid; v_extraid uuid; v_zero uuid; v_zeroid uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_req uuid; v_req2 uuid; v_req_sun uuid; v_req_zero uuid;
  v_reject uuid; v_cancel uuid; v_revoke uuid;
  v_row public.technician_leave_requests;
  v_n int; v_ok boolean;
  v_real_org uuid; v_fp_before int; v_fp_after int; v_setting_before int; v_setting_after int;
begin
  -- ── real-org fingerprint, taken before anything else ──────────────────────────────────────
  select id into v_real_org from organizations where name not like '\_\_TEST\_%' limit 1;
  select count(*) into v_fp_before from technician_availability where org_id = v_real_org;
  select leave_notice_days into v_setting_before from settings where org_id = v_real_org;

  -- ── throwaway org + actors ────────────────────────────────────────────────────────────────
  insert into organizations (name) values ('__TEST_technician_leave_request') returning id into v_org;
  insert into settings (org_id, leave_notice_days, lead_work_days) values (v_org, 3, '{1}');

  v_master := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_master, 'authenticated', 'authenticated', 'leave-master@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  v_t1 := gen_random_uuid(); v_t2 := gen_random_uuid(); v_ctrl := gen_random_uuid();
  v_sun := gen_random_uuid(); v_extra := gen_random_uuid(); v_zero := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 'leave-t1@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 'leave-t2@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_ctrl, 'authenticated', 'authenticated', 'leave-ctrl@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_sun, 'authenticated', 'authenticated', 'leave-sun@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_extra, 'authenticated', 'authenticated', 'leave-extra@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_zero, 'authenticated', 'authenticated', 'leave-zero@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_ctrl, v_org, '__TEST_ ctrl', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_sun, v_org, '__TEST_ sun', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_extra, v_org, '__TEST_ extra', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_zero, v_org, '__TEST_ zero', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1id;
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2id;
  insert into technicians (org_id, profile_id) values (v_org, v_ctrl) returning id into v_ctrlid;
  insert into technicians (org_id, profile_id) values (v_org, v_sun) returning id into v_sunid;
  insert into technicians (org_id, profile_id) values (v_org, v_extra) returning id into v_extraid;
  insert into technicians (org_id, profile_id) values (v_org, v_zero) returning id into v_zeroid;

  -- ══ KPI exclusion (reward_candidates' "expected working days") ═══════════════════════════
  -- organisation working days this month, per lead_work_days={1}: Mondays 2026-03-02/09/16/23/30
  -- (5 days). Control technician present on all five.
  insert into attendance (org_id, technician_id, date, check_in_at, is_late) values
    (v_org, v_ctrlid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-16', '2026-03-16 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-30', '2026-03-30 09:00+05:30', false),
    -- t1: present the first four Mondays, misses the fifth (2026-03-30) — will be protected leave
    (v_org, v_t1id, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-16', '2026-03-16 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- t2: same shortfall, will be LATE (not protected) leave on 2026-03-30
    (v_org, v_t2id, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-16', '2026-03-16 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- sun: same shortfall (misses 2026-03-30), will have a protected, in-advance leave on a
    -- SUNDAY only (2026-03-29) — a non-working day, so it must not cover the missing Monday
    (v_org, v_sunid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_sunid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_sunid, '2026-03-16', '2026-03-16 09:00+05:30', false),
    (v_org, v_sunid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- extra: same shortfall (misses 2026-03-30), but has EXTRA attendance on a non-working day
    -- (2026-03-31, a Tuesday) — that extra day must not substitute for the missing Monday
    (v_org, v_extraid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-16', '2026-03-16 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-31', '2026-03-31 09:00+05:30', false);
    -- zero: no attendance rows at all (inserted below: a full-month protected leave instead)

  -- t1: requested 2026-03-01 for 2026-03-30 (well ahead of leave_notice_days=3) -> protected
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t1id, '2026-03-30', '2026-03-30', v_t1, '2026-03-01 10:00+05:30')
    returning id into v_req;
  -- t2: requested 2026-03-29 for 2026-03-30 (1 day's notice, < 3) -> NOT protected = "late"
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t2id, '2026-03-30', '2026-03-30', v_t2, '2026-03-29 10:00+05:30')
    returning id into v_req2;
  -- sun: requested well ahead, but for 2026-03-29 (Sunday) only
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_sunid, '2026-03-29', '2026-03-29', v_sun, '2026-02-01 10:00+05:30')
    returning id into v_req_sun;
  -- zero: requested well ahead, 2026-03-01..2026-03-30 (29-day span, the max a single request
  -- may cover) -- still covers all 5 Mondays
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_zeroid, '2026-03-01', '2026-03-30', v_zero, '2026-02-01 10:00+05:30')
    returning id into v_req_zero;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select * into v_row from decide_technician_leave(v_req, 'approved');
  res := res || E'\n' || format('t1 (in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req2, 'approved');
  res := res || E'\n' || format('t2 (late) approved, protected (expect false): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_sun, 'approved');
  res := res || E'\n' || format('sun (Sunday only, in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_zero, 'approved');
  res := res || E'\n' || format('zero (whole month, in advance) approved, protected (expect true): %s', v_row.protected);

  -- test 1: in-advance protected leave + attendance on every other working day -> eligible
  select count(*) = 1 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t1id;
  res := res || E'\n' || format('test1 protected t1 eligible for attendance reward (expect true): %s', v_ok);

  -- test 2: same shortfall, late (not in-advance) leave -> not eligible
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t2id;
  res := res || E'\n' || format('test2 late t2 NOT eligible (expect true): %s', v_ok);

  -- test 3: protected leave on a Sunday does not count -- technician_protected_leave_days must
  -- return 0 for it, and the technician (still missing a real Monday) must not be eligible
  select technician_protected_leave_days(v_org, v_sunid, '2026-03-01', '2026-03-31') = 0 into v_ok;
  res := res || E'\n' || format('test3 Sunday-only protected leave counts as 0 days (expect true): %s', v_ok);
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_sunid;
  res := res || E'\n' || format('test3 sun NOT eligible -- Sunday leave does not cover the missing Monday (expect true): %s', v_ok);

  -- test 4: extra attendance on a non-working day (2026-03-31, a Tuesday) does not cover the
  -- missing working day (2026-03-30, the fifth Monday)
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_extraid;
  res := res || E'\n' || format('test4 extra NOT eligible -- non-working-day attendance does not substitute (expect true): %s', v_ok);

  -- test 5: zero real attendance, even with a full month of protected leave covering every
  -- working day, is not eligible (never appears in attendance_agg at all, so never reaches
  -- attendance_eligible regardless of how many protected days it has)
  select technician_protected_leave_days(v_org, v_zeroid, '2026-03-01', '2026-03-31') = 5 into v_ok;
  res := res || E'\n' || format('test5 zero''s whole-month leave covers all 5 working Mondays (expect true): %s', v_ok);
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_zeroid;
  res := res || E'\n' || format('test5 zero NOT eligible -- zero real attendance (expect true): %s', v_ok);

  select count(*) into v_n from technician_availability where leave_request_id = v_req and status = 'leave' and protected;
  res := res || E'\n' || format('t1 approved leave materialised as protected technician_availability row (expect 1): %s', v_n);

  execute 'reset role';

  -- ══ status transitions: reject / cancel / revoke (today-relative, independent technician v_t1) ══
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select (request_technician_leave(v_today + 15, v_today + 15, 'reject me')).id into v_reject;
  select (request_technician_leave(v_today + 16, v_today + 16, 'cancel me')).id into v_cancel;
  select (request_technician_leave(v_today + 17, v_today + 17, 'revoke me')).id into v_revoke;
  res := res || E'\n' || 'three pending requests created for t1 (today+15/16/17)';

  -- overlap with an existing pending request is refused by the database
  begin
    perform request_technician_leave(v_today + 17, v_today + 17, 'dup');
    res := res || E'\n' || 'overlap: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlap: rejected ('||sqlerrm||')';
  end;

  -- date validation refused by the database
  begin
    perform request_technician_leave(v_today + 20, v_today + 19, null);
    res := res || E'\n' || 'end before start: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'end before start: rejected ('||sqlerrm||')';
  end;
  begin
    perform request_technician_leave(v_today, v_today, null);
    res := res || E'\n' || 'start not in the future: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'start not in the future: rejected ('||sqlerrm||')';
  end;
  begin
    perform request_technician_leave(v_today + 30, v_today + 65, null);
    res := res || E'\n' || 'request over 30 days: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'request over 30 days: rejected ('||sqlerrm||')';
  end;

  -- a technician cannot approve their own request, or anyone else's
  begin
    perform decide_technician_leave(v_reject, 'approved', null);
    res := res || E'\n' || 'technician approves own request: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician approves own request: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';

  -- master rejects / t1 cancels / master approves then revokes
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from decide_technician_leave(v_reject, 'rejected', 'not enough cover that week');
  res := res || E'\n' || format('reject: status (expect rejected): %s', v_row.status);
  select * into v_row from decide_technician_leave(v_revoke, 'approved');
  res := res || E'\n' || format('pre-revoke approve: status (expect approved): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('pre-revoke: availability row exists (expect 1): %s', v_n);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from cancel_technician_leave(v_cancel);
  res := res || E'\n' || format('t1 cancels own pending request: status (expect cancelled): %s', v_row.status);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from decide_technician_leave(v_revoke, 'revoked', 'cover arranged, leave withdrawn');
  res := res || E'\n' || format('revoke: status (expect revoked): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('post-revoke: availability row removed (expect 0): %s', v_n);
  execute 'reset role';

  -- ══ RLS: one technician cannot see another technician's requests ═══════════════════════════
  perform set_config('request.jwt.claims', json_build_object('sub', v_t2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_leave_requests where technician_id = v_t1id;
  res := res || E'\n' || format('t2 sees t1''s requests (expect 0): %s', v_n);
  select count(*) > 0 into v_ok from technician_leave_requests where technician_id = v_t2id;
  res := res || E'\n' || format('t2 sees own requests (expect true): %s', v_ok);
  -- t2 also cannot approve t1's untouched request, or anyone's
  begin
    perform decide_technician_leave(v_req, 'approved', null);
    res := res || E'\n' || 'technician approves someone else''s request: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician approves someone else''s request: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- ══ real-org data unchanged ═════════════════════════════════════════════════════════════
  select count(*) into v_fp_after from technician_availability where org_id = v_real_org;
  select leave_notice_days into v_setting_after from settings where org_id = v_real_org;
  res := res || E'\n' || format('real org technician_availability count unchanged (expect true): %s', v_fp_before = v_fp_after);
  res := res || E'\n' || format('real org leave_notice_days unchanged (expect true): %s', v_setting_before = v_setting_after);

  raise exception E'RESULTS%', res;
end $t$;
$TEST_BODY$;
  -- recorded 'live' body of reward_candidates as of 20261016110000_test_customer_flag.sql:896-1005
  -- (the last migration to create-or-replace it before this one) -- verified against the actual
  -- live function below, not trusted blindly.
  v_reward_candidates_recorded_original text := $ORIG_REWARD_CANDIDATES$create or replace function public.reward_candidates(p_org_id uuid, p_period date)
 RETURNS TABLE(category reward_category, technician_id uuid, metric numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', p_period)::date;
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
    -- "Expected working days" is derived from the data itself (no
    -- weekly-off/working-days master exists in this schema — see file
    -- header): every calendar date this month at least one technician in
    -- the org has an attendance row for, i.e. a day the org operated.
    select distinct a.date
    from public.attendance a
    where a.org_id = p_org_id
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
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
  attendance_agg as (
    -- Full attendance: a row on every org-operating day this month.
    select a.technician_id, count(distinct a.date) as days_present
    from public.attendance a
    where a.org_id = p_org_id
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
    group by a.technician_id
    having count(distinct a.date) = (select n from org_day_count)
  ),
  attendance_eligible as (
    select aa.technician_id, coalesce(lh.late_hours, 0) as late_hours
    from attendance_agg aa
    left join late_hours_agg lh on lh.technician_id = aa.technician_id
    where coalesce(lh.late_hours, 0) <= 3
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
$ORIG_REWARD_CANDIDATES$;
  v_mig_hash text;
  v_test_hash text;
  v_result text;
  v_live_def_md5 text;
  v_recreated_def_md5 text;
  v_real_org uuid;
  v_avail_count_before int;
  v_avail_fp_before text;
  v_leave_req_count_before int;
  v_avail_count_after int;
  v_avail_fp_after text;
  v_leave_req_count_after int;
  v_notice_days_before int;
begin
  if (clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00' then
    raise exception 'rehearsal refused: must run at or after 18:00 IST';
  end if;

  v_mig_hash := encode(sha256(convert_to(v_migration, 'UTF8')), 'hex');
  v_test_hash := encode(sha256(convert_to(v_test, 'UTF8')), 'hex');

  if v_mig_hash <> '3990cc41680ca3df71823be3aff15c41ff821024ebe9bfda8a9d5242564f6648' then
    raise exception 'migration hash mismatch: expected 3990cc41680ca3df71823be3aff15c41ff821024ebe9bfda8a9d5242564f6648, got %', v_mig_hash;
  end if;
  if v_test_hash <> '77f622c5e63d01f3846e4d72403be4025096260380a49d92ae8ac2fbac61018e' then
    raise exception 'test hash mismatch: expected 77f622c5e63d01f3846e4d72403be4025096260380a49d92ae8ac2fbac61018e, got %', v_test_hash;
  end if;

  -- ── reward_candidates drift check: is our recorded 'original' body still the live one? ──────
  select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure)) into v_live_def_md5;

  begin
    execute v_reward_candidates_recorded_original;
    select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure)) into v_recreated_def_md5;
    raise exception 'rehearsal: forced rollback of the reward_candidates drift-check sub-block';
  exception when others then
    if sqlerrm <> 'rehearsal: forced rollback of the reward_candidates drift-check sub-block' then
      raise;
    end if;
  end;

  if v_recreated_def_md5 is distinct from v_live_def_md5 then
    raise exception 'reward_candidates drift: the live function (md5 %) no longer matches the body recorded from 20261016110000 (md5 %) -- refusing, this migration''s create-or-replace must be re-based on the real current body first', v_live_def_md5, v_recreated_def_md5;
  end if;

  -- ── real-org fingerprint, taken before anything else ──────────────────────────────────────
  select id into v_real_org from organizations where name not like '\_\_TEST\_%' limit 1;
  select count(*),
         coalesce(md5(string_agg(technician_id::text || ':' || date::text || ':' || status, ',' order by technician_id, date)), '')
    into v_avail_count_before, v_avail_fp_before
    from technician_availability where org_id = v_real_org;
  select leave_notice_days into v_notice_days_before from settings where org_id = v_real_org;
  -- technician_leave_requests does not exist yet at this point -- there is nothing of this
  -- org's to fingerprint there before the migration creates the table.

  execute v_migration;

  begin
    execute v_test;
    v_result := 'RESULTS(test did not raise -- unexpected, treat as FAIL)';
  exception when others then
    v_result := sqlerrm;
  end;

  -- ── real-org fingerprint, compared at the end ─────────────────────────────────────────────
  select count(*),
         coalesce(md5(string_agg(technician_id::text || ':' || date::text || ':' || status, ',' order by technician_id, date)), '')
    into v_avail_count_after, v_avail_fp_after
    from technician_availability where org_id = v_real_org;
  select count(*) into v_leave_req_count_after from technician_leave_requests where org_id = v_real_org;

  v_result := v_result || E'
' || format('real org technician_availability count unchanged (expect true): %s', v_avail_count_before = v_avail_count_after);
  v_result := v_result || E'
' || format('real org technician_availability content fingerprint unchanged (expect true): %s', v_avail_fp_before = v_avail_fp_after);
  v_result := v_result || E'
' || format('real org technician_leave_requests untouched by the migration/test (expect 0): %s', v_leave_req_count_after);
  v_result := v_result || E'
' || format('real org leave_notice_days before the migration (expect null -- column did not exist yet): %s', v_notice_days_before);

  raise exception '%', v_result;
end
$w$;
