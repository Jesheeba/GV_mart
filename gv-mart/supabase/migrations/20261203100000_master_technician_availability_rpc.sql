-- Urgent item #5: availability-assisted scheduling for the master's
-- create/assign-complaint flow (either pick a technician first and see
-- their free/busy slots on a date, or pick a date/time first and see which
-- technicians are free then). NOT APPLIED — this file only. Per the
-- standing migration policy it needs: rehearsal via
-- _local_only/reports/run_rehearsal.mjs, DRYRUN-OK, an independent
-- string-literal review, and the owner's typed "APPROVED" before anyone
-- runs it against the live database.
--
-- READ-ONLY, ADDITIVE: one new read-only RPC
-- (get_technician_availability_for_date) plus two private helpers it calls.
-- Nothing existing is altered, no table/column/constraint changes, no
-- trigger changes. Safe to apply independently of item #4 (the date/
-- timezone scheduling fix on fix/urgent-item4-scheduling) — this migration
-- does not touch _visit_start_ts, _appt_range, or any other function item
-- #4 might change; it only CALLS the existing, unmodified _appt_range.
--
-- WHY NO NEW OVERLAP LOGIC: the technician-busy-at-a-time question is
-- already answered, exactly once, by 20261016100000_amc_cancel_visit_
-- scheduling_overlap.sql's _appt_range(scheduled_at, ends_at) (the same
-- tstzrange('[)') the appointments_technician_no_overlap EXCLUDE constraint
-- and _tech_conflict_appt/_tech_busy_at use for every assignment decision
-- in this schema). _tech_day_busy_windows below calls _appt_range directly
-- and intersects it with the requested day via the same '&&' operator — it
-- does not re-derive "is this appointment on this day" or "do these two
-- ranges overlap" by any other comparison. The only genuinely new geometry
-- is turning a list of busy windows into the COMPLEMENT (the free gaps) for
-- display, which mirrors (same merge-overlapping-intervals algorithm, same
-- half-open comparison) _largest_free_window from 20260723100000_step4_
-- booking_model_schema.sql, except it returns every surviving gap instead
-- of only the largest — that one difference is why this is a new function
-- (_free_gaps) rather than a call to the existing one.
--
-- WHY READ-ONLY / WHY SECURITY DEFINER SCOPED THE WAY IT IS: this RPC never
-- writes anything. Actual booking still goes through the existing, already-
-- reviewed write paths: create_complaint_ticket (ticket creation, with
-- p_auto_assign=false when the master wants to assign manually) and
-- assign_ticket_technician (binding a technician to an appointment — same
-- function, same force-override + "technician is busy" warning the UI
-- already surfaces, reused unchanged here; see service.assign.technicianBusy
-- in en.json/ta.json). This migration adds no new way to create or move an
-- appointment, so there's no new double-booking surface to reason about
-- beyond what assign_ticket_technician already guards.
--
-- SECURITY DEFINER is used (not INVOKER) because the function deliberately
-- reads across every technician in the org — a technician must NOT be able
-- to see another technician's schedule by calling this RPC, which plain
-- RLS alone would not stop if the technician could somehow still read the
-- appointments/technician_availability rows; the explicit is_ops_staff()
-- check at the top is the actual gate; current_org_id() scoping is the
-- cross-org gate. Both are enforced before any row is touched, same
-- pattern as every other staff-only RPC in this schema
-- (assign_ticket_technician, technician_assigned_visits_in_range, etc).

-- ── private helper #1: a technician's merged busy windows on one IST day,
--    expressed as local HH:MM pairs, built ONLY from _appt_range (the
--    existing overlap-range helper) intersected with that day ───────────
create or replace function public._tech_day_busy_windows(p_tech uuid, p_date date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with day_range as (
    select tstzrange(
      (p_date::timestamp) at time zone 'Asia/Kolkata',
      ((p_date + 1)::timestamp) at time zone 'Asia/Kolkata',
      '[)'
    ) as r
  ),
  -- Same filter (status, technician) _tech_conflict_appt uses, and the same
  -- _appt_range(scheduled_at, ends_at) tstzrange it intersects with '&&' —
  -- here against the requested day's range instead of a candidate booking.
  overlapping as (
    select public._appt_range(a.scheduled_at, a.ends_at) as r
    from public.appointments a, day_range dr
    where a.technician_id = p_tech
      and a.status in ('scheduled', 'in_progress')
      and public._appt_range(a.scheduled_at, a.ends_at) && dr.r
  ),
  clipped as (
    select greatest(lower(o.r), lower(dr.r)) as s, least(upper(o.r), upper(dr.r)) as e
    from overlapping o, day_range dr
  ),
  valid as (
    select s, e from clipped where s < e
  ),
  -- Merge-overlapping-intervals, identical approach to _largest_free_window
  -- (20260723100000): a row starts a new group whenever its start is past
  -- the running max end of every earlier row.
  with_prev_max as (
    select s, e,
      max(e) over (order by s rows between unbounded preceding and 1 preceding) as prev_max_e
    from valid
  ),
  grouped as (
    select s, e,
      sum(case when prev_max_e is null or s > prev_max_e then 1 else 0 end) over (order by s) as grp
    from with_prev_max
  ),
  merged as (
    select min(s) as s, max(e) as e from grouped group by grp
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'start', to_char(s at time zone 'Asia/Kolkata', 'HH24:MI'),
        'end', to_char(e at time zone 'Asia/Kolkata', 'HH24:MI')
      )
      order by s
    ),
    '[]'::jsonb
  )
  from merged;
$$;
revoke all on function public._tech_day_busy_windows(uuid, date) from public, anon, authenticated;
grant execute on function public._tech_day_busy_windows(uuid, date) to service_role;

-- ── private helper #2: every free gap in [p_work_start, p_work_end] once
--    p_blocked (jsonb array of {"start":"HH:MM","end":"HH:MM"}) is removed.
--    Same merge-and-gap algorithm as _largest_free_window (20260723100000),
--    deliberately NOT refactored into/out of that live function (it's
--    called from every booking RPC; this migration does not touch it) —
--    instead this returns every gap ordered by start, not only the
--    largest, which is the one behavioural difference the free/busy
--    picker UI needs. ─────────────────────────────────────────────────
create or replace function public._free_gaps(
  p_work_start time,
  p_work_end time,
  p_blocked jsonb
)
returns jsonb
language sql
stable
as $$
  with raw as (
    select
      greatest((elem->>'start')::time, p_work_start) as s,
      least((elem->>'end')::time, p_work_end) as e
    from jsonb_array_elements(coalesce(p_blocked, '[]'::jsonb)) as elem
  ),
  valid as (
    select s, e from raw where s < e
  ),
  with_prev_max as (
    select s, e,
      max(e) over (order by s rows between unbounded preceding and 1 preceding) as prev_max_e
    from valid
  ),
  grouped as (
    select s, e,
      sum(case when prev_max_e is null or s > prev_max_e then 1 else 0 end) over (order by s) as grp
    from with_prev_max
  ),
  merged as (
    select min(s) as s, max(e) as e from grouped group by grp
  ),
  gaps as (
    select lag(e, 1, p_work_start) over (order by s) as gap_start, s as gap_end from merged
    union all
    select coalesce((select max(e) from merged), p_work_start), p_work_end
  ),
  ranked as (
    select gap_start, gap_end, (extract(epoch from (gap_end - gap_start))::integer / 60) as minutes
    from gaps
    where gap_end > gap_start
    order by gap_start
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('start', to_char(gap_start, 'HH24:MI'), 'end', to_char(gap_end, 'HH24:MI'), 'minutes', minutes)
      order by gap_start
    ),
    '[]'::jsonb
  )
  from ranked;
$$;
revoke all on function public._free_gaps(time, time, jsonb) from public, anon, authenticated;
grant execute on function public._free_gaps(time, time, jsonb) to service_role;

-- ── the RPC itself: master/operation_admin only, org-scoped, read-only ──
-- p_technician_id null  -> "date-first": every active technician in the
--   org on p_date (the master picks one from the results).
-- p_technician_id set   -> "technician-first": just that technician, same
--   shape (the master already picked them, now picks a free slot).
-- Either way the caller must be master/operation_admin for THIS org — a
-- technician calling this (even for their own id) is rejected; technicians
-- already have their own schedule via the technician app's existing
-- queries, this RPC is for the admin assignment screens only.
create or replace function public.get_technician_availability_for_date(
  p_org_id uuid,
  p_date date,
  p_technician_id uuid default null
)
returns table (
  technician_id uuid,
  technician_name text,
  is_on_leave boolean,
  work_start time,
  work_end time,
  busy_windows jsonb,
  free_windows jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_work_start time;
  v_work_end time;
begin
  if not public.is_ops_staff() then
    raise exception 'get_technician_availability_for_date: master or operation_admin role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'get_technician_availability_for_date: org mismatch';
  end if;
  if p_date is null then
    raise exception 'get_technician_availability_for_date: date is required';
  end if;
  if p_technician_id is not null and not exists (
    select 1 from public.technicians tt where tt.id = p_technician_id and tt.org_id = p_org_id
  ) then
    raise exception 'get_technician_availability_for_date: technician % not found in org %', p_technician_id, p_org_id;
  end if;

  select s.work_start, s.work_end into v_work_start, v_work_end
  from public.settings s where s.org_id = p_org_id;
  v_work_start := coalesce(v_work_start, '09:15'::time);
  v_work_end := coalesce(v_work_end, '17:30'::time);

  return query
  select
    t.id,
    p.full_name,
    coalesce(lv.on_leave, false),
    v_work_start,
    v_work_end,
    bw.busy,
    case when coalesce(lv.on_leave, false) then '[]'::jsonb
         else public._free_gaps(v_work_start, v_work_end, bw.busy)
    end
  from public.technicians t
  join public.profiles p on p.id = t.profile_id
  left join lateral (
    select exists (
      select 1 from public.technician_availability ta
      where ta.technician_id = t.id and ta.date = p_date and ta.status = 'leave'
    ) as on_leave
  ) lv on true
  left join lateral (
    select public._tech_day_busy_windows(t.id, p_date) as busy
  ) bw on true
  where t.org_id = p_org_id
    and t.is_active = true
    and (p_technician_id is null or t.id = p_technician_id)
  order by p.full_name;
end;
$$;
revoke all on function public.get_technician_availability_for_date(uuid, date, uuid) from public, anon, authenticated;
grant execute on function public.get_technician_availability_for_date(uuid, date, uuid) to authenticated;

notify pgrst, 'reload schema';
