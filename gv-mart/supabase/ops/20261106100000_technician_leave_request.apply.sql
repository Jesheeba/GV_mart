-- GO APPLY for 20261106100000_technician_leave_request.sql.
-- One DO block, followed by one read-only status SELECT as a separate statement. The DO block
-- applies the migration FOR REAL and commits, but only if every one of the following checks
-- passes, in order; the first failure raises and the entire statement (migration +
-- registration + post-checks) rolls back atomically -- there is no forced rollback at the end
-- the way the rehearsal wrapper has one. No test file is embedded or run here; the test already
-- ran clean in the rehearsal (see leave_wrapper_run.sql.out.txt).
--
-- Order of checks: lock_timeout -> real-organisation fingerprint -> exactly-one-real-org ->
-- 18:00 IST gate -> CR-tolerant migration hash -> not-already-registered -> reward_candidates
-- live-definition drift (the only pre-existing function this migration redefines) ->
-- pre-migration technician_availability fingerprint -> EXECUTE the migration -> register the
-- version in supabase_migrations.schema_migrations -> read-only post-checks (new
-- tables/columns exist, settings.leave_notice_days default is 1, zero public-schema functions
-- executable by PUBLIC/anon, the six leave functions specifically refused to anon/PUBLIC,
-- technician_availability row count and content fingerprint for the real org unchanged).
--
-- Read-only pre-apply review (2026-10-28, via the same Management API path, nothing changed):
--   select count(*) from organizations where name not like '\_\_TEST\_%'           -> 1
--   count(*) of pg_proc in public with EXECUTE granted to PUBLIC/anon via aclexplode -> 0
--   supabase_migrations.schema_migrations columns: version text not null,
--     name text, statements text[] (confirmed via information_schema.columns);
--     3 most recent existing rows all have non-null statements.
-- Because the public/anon-exec count was 0 at review time, the schema-wide post-check below is
-- left as an absolute zero-count assertion (not a before/after new-functions-only diff) --
-- if it is ever non-zero for an unrelated reason by the time this actually runs, refusing is
-- the correct, intended behaviour, not a false positive to work around.
do $go$
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

-- ── settings ─────────────────────────────────────────────────────────────────────────────────
alter table public.settings
  add column if not exists leave_notice_days integer not null default 1
    check (leave_notice_days >= 0);

-- reward_candidates' attendance category (below) requires a technician to actually have shown up
-- for at least this fraction of the month's organisation working days, not just have every day
-- covered by a mix of attendance and protected leave -- otherwise a technician who was on
-- protected leave almost the entire month could still win "most reliable attendance".
alter table public.settings
  add column if not exists attendance_reward_min_present_ratio numeric not null default 0.5
    check (attendance_reward_min_present_ratio > 0 and attendance_reward_min_present_ratio <= 1);

-- ── the request table ───────────────────────────────────────────────────────────────────────
create extension if not exists btree_gist with schema extensions;

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
revoke all on public.technician_leave_requests from public, anon, authenticated;
grant select on public.technician_leave_requests to authenticated;

create trigger set_updated_at before update on public.technician_leave_requests
  for each row execute function public.set_updated_at();

-- Same audit trigger every other master table uses (20261011110000_audit_log_append_only.sql's
-- current body) — keeps the full history of status changes/decisions in audit_log for free, no
-- separate history table needed. technician_leave_requests already has the id/org_id columns it
-- requires.
create trigger audit_technician_leave_requests after insert or update or delete on public.technician_leave_requests
  for each row execute function public.audit_master_change();

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
  v_was_approved boolean;
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

  v_was_approved := (v_row.status = 'approved');
  if v_was_approved then
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

  if v_was_approved then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    select v_row.org_id, r, 'technician_leave_cancelled_by_technician', 'Leave cancelled by technician',
      format('An approved leave from %s to %s was cancelled by the technician.', to_char(v_row.start_date, 'DD Mon YYYY'), to_char(v_row.end_date, 'DD Mon YYYY')), v_row.id
    from unnest(array['master', 'operation_admin']::user_role[]) as r;
  end if;

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
  if p_decision = 'approved' and v_row.start_date < v_today then
    raise exception 'decide_technician_leave: this request has already started; reject it';
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

    -- A day that already carries a pre-existing 'leave' row (admin-direct entry, the only way
    -- the conflict check above still let this through) is left completely alone: DO NOTHING, not
    -- linked to this request. It was never this request's day to claim, and cancel/revoke below
    -- only ever touch rows with leave_request_id = this request, so a pre-existing admin-entered
    -- leave day always survives this request being cancelled or revoked.
    insert into public.technician_availability (org_id, technician_id, date, status, leave_request_id, protected)
    select v_row.org_id, v_row.technician_id, g.d::date, 'leave', p_request_id, v_protected
    from generate_series(v_row.start_date, v_row.end_date, interval '1 day') g(d)
    on conflict (technician_id, date) do nothing;

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

-- ── KPI exclusion: the shared count of protected leave days in a period, callable by the front
--    end to show "N day(s) excluded" on the technician table (reward_candidates below computes
--    its own per-day coverage directly, it does not call this). Counts only days whose ISO
--    weekday is in the org's weekly pattern (settings.lead_work_days — the same column the
--    lead-followup and AMC/rental "roll to next working day" logic already reads, reused here
--    rather than inventing a second org-working-day setting). A leave day that falls on a day the
--    org doesn't operate (e.g. Sunday) was never an "expected working day" to begin with, so it
--    is not protected leave either. Unlike reward_candidates' own org_days, this display helper
--    does not also require that someone else attended that day — it's a simpler figure for a
--    single technician's own history, not an eligibility gate. This schema has no separate
--    holiday calendar, so a gazetted holiday on an otherwise-working weekday is NOT excluded
--    here; that is a real gap, not something silently pretended to be handled. ─────────────────
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
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_protected_leave_days: org mismatch';
  end if;
  -- is_staff(), not is_ops_staff(): a technician may also call this for their own id.
  if not (public.is_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_protected_leave_days: access denied';
  end if;
  if p_from > p_to then
    return 0;
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
--      1. org_days is now a weekly working-day pattern (settings.lead_work_days) AND-ed with
--         "at least one technician actually has an attendance row that day" — a closed weekday
--         (e.g. Sunday) with a stray attendance row never becomes an expected day (the weekday
--         filter), and a normally-working weekday nobody attended at all (e.g. a company holiday
--         — this schema has no separate holiday calendar) never becomes one either (the
--         attendance-exists filter). This also closes the old bug where a single technician's
--         own anomalous attendance on a non-working day silently made that day "expected" of
--         everyone else too.
--      2. Eligibility is now computed PER DAY, not by adding two separate counts. day_coverage
--         cross-joins every technician against every org_day and marks each day covered if there
--         is an attendance row OR the day falls inside an approved, protected leave range —
--         OR'd, not added, so a day that happens to be both (nothing in this schema prevents a
--         technician from both checking in and being on approved leave the same day) is never
--         double-counted into "more covered days than there are days". coverage_agg then counts
--         covered days and, separately, real attended days per technician.
--      3. attendance_eligible now also requires attended_days >= ceil(org_day_count *
--         settings.attendance_reward_min_present_ratio, default 0.5) — a technician on protected
--         leave for nearly the whole month, with every day otherwise covered, still should not
--         win "most reliable attendance" without a real minimum of actual attendance.
--      4. The review/revenue/referral CTEs have nothing to do with leave and are untouched. ─────
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
  v_min_present_ratio numeric;
begin
  if not public.is_staff() then
    raise exception 'reward_candidates: staff role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'reward_candidates: org mismatch';
  end if;

  select late_cutoff, attendance_reward_min_present_ratio
    into v_late_cutoff, v_min_present_ratio
    from public.settings where org_id = p_org_id;
  v_late_cutoff := coalesce(v_late_cutoff, '09:15:00'::time);
  v_min_present_ratio := coalesce(v_min_present_ratio, 0.5);

  return query
  with org_days as (
    -- An organisation working day: a calendar date this month whose ISO weekday is in the org's
    -- configured weekly pattern (settings.lead_work_days — the same column the lead-followup and
    -- AMC/rental "roll to next working day" logic already reads, reused here rather than
    -- inventing a second org-working-day setting) AND on which at least one technician actually
    -- has an attendance row. See the header note above for why both conditions are required.
    select d::date as date
    from generate_series(v_period, v_period_end, interval '1 day') d
    where extract(isodow from d)::smallint = any (
            coalesce((select s.lead_work_days from public.settings s where s.org_id = p_org_id), '{1,2,3,4,5,6}'::smallint[])
          )
      and exists (
            select 1 from public.attendance a where a.org_id = p_org_id and a.date = d::date
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
  -- Per technician, per organisation working day: covered if there is an attendance row that day
  -- OR the day falls inside an approved, protected leave request.
  day_coverage as (
    select t.id as technician_id, od.date,
      exists (
        select 1 from public.attendance a
        where a.org_id = p_org_id and a.technician_id = t.id and a.date = od.date
      ) as attended,
      exists (
        select 1 from public.technician_leave_requests r
        where r.org_id = p_org_id and r.technician_id = t.id and r.status = 'approved' and r.protected
          and r.period @> od.date
      ) as on_protected_leave
    from public.technicians t
    cross join org_days od
    where t.org_id = p_org_id
  ),
  coverage_agg as (
    select dc.technician_id,
      count(*) filter (where dc.attended or dc.on_protected_leave) as covered_days,
      count(*) filter (where dc.attended) as attended_days
    from day_coverage dc
    group by dc.technician_id
  ),
  attendance_eligible as (
    select ca.technician_id, coalesce(lh.late_hours, 0) as late_hours
    from coverage_agg ca
    left join late_hours_agg lh on lh.technician_id = ca.technician_id
    where ca.covered_days = (select n from org_day_count)
      and ca.attended_days >= ceil((select n from org_day_count) * v_min_present_ratio)
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
  -- recorded 'live' body of reward_candidates as of 20261016110000_test_customer_flag.sql:896-1005
  -- (the last migration to create-or-replace it before this one) -- same text already verified
  -- against the actual live function in the rehearsal (leave_wrapper_run.sql), not re-typed here.
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
  v_org_fingerprint text;
  v_real_org uuid;
  v_real_org_count int;
  v_already_registered boolean;
  v_live_def_md5 text;
  v_recreated_def_md5 text;
  v_avail_count_before int;
  v_avail_fp_before text;
  v_avail_count_after int;
  v_avail_fp_after text;
  v_n int;
  v_col_default text;
begin
  perform set_config('lock_timeout', '5s', true);

  -- Real-organisation fingerprint check, before anything else: refuses outright unless this
  -- apply is running against the one specific real organisation it was written for.
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
    from public.organizations o
    where o.name not like '\_\_TEST\_%'
    order by o.created_at asc
    limit 1;
  if v_org_fingerprint is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'GO_APPLY_REFUSED: organisation fingerprint mismatch';
  end if;

  -- Refuses outright unless exactly one non-test organisation exists -- more than one makes
  -- "the real organisation" ambiguous, and picking one silently would hide that ambiguity.
  select count(*) into v_real_org_count from organizations where name not like '\_\_TEST\_%';
  if v_real_org_count <> 1 then
    raise exception 'GO_APPLY_REFUSED: expected exactly one non-test organisation, found %', v_real_org_count;
  end if;
  select id into v_real_org from organizations where name not like '\_\_TEST\_%';

  -- The real gate for an actual apply is 18:00 IST (the rehearsal-only 11:00 lowering does not
  -- apply here -- this script was written fresh, not derived from the lowered rehearsal file).
  if (clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00' then
    raise exception 'GO_APPLY_REFUSED: must run at or after 18:00 IST';
  end if;

  -- CR-tolerant: hash and execute the CR-stripped text, so a CRLF-mangled copy of this file
  -- still matches the pinned LF hash below and still runs correctly -- the pin itself stays
  -- the LF-byte hash of the committed migration file.
  v_mig_hash := encode(sha256(convert_to(replace(v_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_mig_hash <> '025654ea3669c3f68500a1b0b901b5888c83d1ac5e5abd7f71b6af78e9ba7517' then
    raise exception 'GO_APPLY_REFUSED: migration hash mismatch: expected 025654ea3669c3f68500a1b0b901b5888c83d1ac5e5abd7f71b6af78e9ba7517, got %', v_mig_hash;
  end if;

  -- Refuse if this version is already registered -- re-applying it would be a mistake, not a
  -- retry, since the migration itself is not idempotent-safe to run twice (e.g. the GIST
  -- exclusion constraint and the policy/trigger CREATE statements are not all "if not exists").
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = '20261106100000'
  ) into v_already_registered;
  if v_already_registered then
    raise exception 'GO_APPLY_REFUSED: migration 20261106100000 is already registered in supabase_migrations.schema_migrations';
  end if;

  -- ── live-definition pre-check: reward_candidates is the only pre-existing function this
  --    migration redefines (every other function it creates is brand new, so there is no "live
  --    before" to drift-check). Recreates the recorded-original body in a sub-block purely to
  --    get its normalised md5 via pg_get_functiondef, then forces that sub-block to roll back
  --    (it must never actually replace the live function), and compares that md5 against the
  --    md5 of the function as it is actually live right now, BEFORE this migration touches it.
  select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure)) into v_live_def_md5;

  begin
    execute replace(v_reward_candidates_recorded_original, E'\r', '');
    select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure)) into v_recreated_def_md5;
    raise exception 'go_apply: forced rollback of the reward_candidates drift-check sub-block';
  exception when others then
    if sqlerrm <> 'go_apply: forced rollback of the reward_candidates drift-check sub-block' then
      raise;
    end if;
  end;

  if v_recreated_def_md5 is distinct from v_live_def_md5 then
    raise exception 'GO_APPLY_REFUSED: reward_candidates drift: the live function (md5 %) no longer matches the body recorded from 20261016110000 (md5 %) -- this migration''s create-or-replace must be re-based on the real current body first', v_live_def_md5, v_recreated_def_md5;
  end if;

  -- ── pre-migration fingerprint of the real org's technician_availability, compared again
  --    after the migration runs (below) -- the migration must not change any existing row.
  select count(*),
         coalesce(md5(string_agg(technician_id::text || ':' || date::text || ':' || status, ',' order by technician_id, date)), '')
    into v_avail_count_before, v_avail_fp_before
    from technician_availability where org_id = v_real_org;

  -- ══ APPLY FOR REAL ══════════════════════════════════════════════════════════════════════
  execute replace(v_migration, E'\r', '');

  -- ── register the version, matching the shape of the existing rows (version/name/statements
  --    as supabase_migrations.schema_migrations actually uses them -- confirmed live:
  --    version text not null, name text, statements text[]). name follows the same
  --    timestamp_name convention as every sibling row (filename minus the "<version>_" prefix
  --    and ".sql" suffix). statements is simplified to one element holding the whole
  --    (CR-stripped) migration text, rather than attempting a semicolon-based split that would
  --    misparse the dollar-quoted function bodies this migration is full of -- the column is
  --    informational bookkeeping, not re-executed from here, so a single-element array is an
  --    honest "shape match" without pretending a false per-statement precision. Same
  --    transaction as the migration above and every check below -- if anything from here on
  --    raises, this insert rolls back along with everything else.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (
    '20261106100000',
    'technician_leave_request',
    array[replace(v_migration, E'\r', '')]
  );

  -- ══ post-migration read-only checks -- any failure here rolls back the whole apply ════════

  -- new table + new columns exist
  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'technician_leave_requests'
  ) then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: public.technician_leave_requests is missing after the migration';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'technician_availability' and column_name = 'leave_request_id'
  ) then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: technician_availability.leave_request_id is missing after the migration';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'technician_availability' and column_name = 'protected'
  ) then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: technician_availability.protected is missing after the migration';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'settings' and column_name = 'leave_notice_days'
  ) then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: settings.leave_notice_days is missing after the migration';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'settings' and column_name = 'attendance_reward_min_present_ratio'
  ) then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: settings.attendance_reward_min_present_ratio is missing after the migration';
  end if;

  -- settings.leave_notice_days has default 1
  select column_default into v_col_default
    from information_schema.columns
    where table_schema = 'public' and table_name = 'settings' and column_name = 'leave_notice_days';
  if v_col_default is null or v_col_default !~ '^1(::integer)?$' then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: settings.leave_notice_days default is not 1 (got %)', v_col_default;
  end if;

  -- zero functions in schema public executable by PUBLIC or anon (schema-wide invariant, not
  -- limited to the six new functions below -- catches a regression of the 2026-08-27
  -- default-privileges fix for ANY public function, old or new).
  select count(*) into v_n
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = 'anon'::regrole);
  if v_n <> 0 then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: % function(s) in schema public are executable by PUBLIC/anon', v_n;
  end if;

  -- anon cannot execute any of the six leave functions
  if has_function_privilege('anon', 'public.request_technician_leave(date,date,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.cancel_technician_leave(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.decide_technician_leave(uuid,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_assigned_visits_in_range(uuid,date,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.technician_protected_leave_days(uuid,uuid,date,date)', 'EXECUTE')
     or has_function_privilege('anon', 'public._leave_request_is_protected(timestamptz,date,integer)', 'EXECUTE')
  then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: anon can execute at least one of the six leave functions';
  end if;

  -- PUBLIC cannot execute any of the six leave functions
  if has_function_privilege('public', 'public.request_technician_leave(date,date,text)', 'EXECUTE')
     or has_function_privilege('public', 'public.cancel_technician_leave(uuid)', 'EXECUTE')
     or has_function_privilege('public', 'public.decide_technician_leave(uuid,text,text)', 'EXECUTE')
     or has_function_privilege('public', 'public.technician_assigned_visits_in_range(uuid,date,date)', 'EXECUTE')
     or has_function_privilege('public', 'public.technician_protected_leave_days(uuid,uuid,date,date)', 'EXECUTE')
     or has_function_privilege('public', 'public._leave_request_is_protected(timestamptz,date,integer)', 'EXECUTE')
  then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: PUBLIC can execute at least one of the six leave functions';
  end if;

  -- real org technician_availability unchanged by the migration
  select count(*),
         coalesce(md5(string_agg(technician_id::text || ':' || date::text || ':' || status, ',' order by technician_id, date)), '')
    into v_avail_count_after, v_avail_fp_after
    from technician_availability where org_id = v_real_org;
  if v_avail_count_after <> v_avail_count_before then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: real org technician_availability row count changed (% -> %)', v_avail_count_before, v_avail_count_after;
  end if;
  if v_avail_fp_after is distinct from v_avail_fp_before then
    raise exception 'GO_APPLY_POSTCHECK_FAILED: real org technician_availability content fingerprint changed';
  end if;

  -- All checks passed: the DO block falls through here and the statement commits for real.
end
$go$;

-- ── read-only status check, run as its own statement right after the DO block (NOT a NOTICE:
--    an actual SELECT with a real result row, so success/failure is visible however this file
--    is run, including through an API that only surfaces the final statement's rows). If the
--    DO block above raised, nothing it touched committed and this still only reports the
--    unchanged pre-apply state -- it never claims success on its own, it only reports facts.
select
  (select exists(
     select 1 from supabase_migrations.schema_migrations where version = '20261106100000'
   )) as version_registered,
  (select exists(
     select 1 from information_schema.tables
     where table_schema = 'public' and table_name = 'technician_leave_requests'
   )) as table_exists,
  (select exists(
     select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'technician_availability' and column_name = 'leave_request_id'
   )) as availability_leave_request_id_exists,
  (select exists(
     select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'technician_availability' and column_name = 'protected'
   )) as availability_protected_exists,
  (select exists(
     select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'settings' and column_name = 'leave_notice_days'
   )) as settings_leave_notice_days_exists,
  (select exists(
     select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'settings' and column_name = 'attendance_reward_min_present_ratio'
   )) as settings_ratio_exists,
  (select column_default from information_schema.columns
     where table_schema = 'public' and table_name = 'settings' and column_name = 'leave_notice_days'
   ) as leave_notice_days_default,
  (select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure))
  ) as reward_candidates_def_md5;
