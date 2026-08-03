-- Fix: "after marking attendance, the job is not allocated."
--
-- Root cause (confirmed live against production data): technician e4b0986f
-- (skills=['ac']) checks in; the org's 4 open, unassigned tickets all have
-- required_skill='battery'. Neither the ticket-creation-time engine nor the
-- check-in-time backlog scan assigns anything to them, because both live
-- copies of the assignment engine carry a hard skill-match filter:
--
--   and (
--     v_ticket.required_skill is null
--     or t.skills = '{}'
--     or v_ticket.required_skill = any(t.skills)
--   )
--
-- This directly contradicts the explicit, already-shipped product decision
-- in 20260721110000_technician_assignment_g1_skill_nonblocking.sql: the
-- owner reduced product types to RO / Inverter / Battery only, so ALL
-- technicians handle ALL three — there is no specialization split, and
-- "skill must be a true no-op filter" against assignment eligibility.
--
-- The regression: 20260731110000_attendance_gated_assignment.sql redefined
-- _auto_assign_ticket_internal to add the attendance gate, and its own
-- header claimed "skill/capacity filters... untouched — verbatim copy
-- except for the one clause below" — but it was actually copied from a
-- pre-G1 version of the function, silently reintroducing the skill
-- AND-clause G1 had deliberately dropped. 20260731150000's new
-- _auto_assign_next_ticket_to_technician (the check-in/completion backlog
-- scan) was then modeled on that same already-regressed function, so it
-- inherited the same skill filter and was never G1-compliant to begin with.
--
-- Fix: drop the skill AND-clause from both functions' candidate SELECT,
-- exactly as G1 did originally. Everything else (attendance gate, is_active,
-- zone/roster, capacity, ranking) is unchanged — verbatim copy of the
-- currently-live bodies (20260731110000 and 20260731150000 respectively)
-- minus that one clause each.

create or replace function public._auto_assign_ticket_internal(
  p_ticket_id uuid,
  p_org_id uuid,
  p_skip_rating_logic boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket service_tickets;
  v_appointment appointments;
  v_addr addresses;
  v_tech_id uuid;
  v_tech_count integer;
  v_prior_ticket_id uuid;
  v_prior_tech_id uuid;
  v_prior_stars numeric(2,1);
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % not found', p_ticket_id;
  end if;

  select * into v_appointment from public.appointments
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress')
  order by created_at desc limit 1;
  if v_appointment.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % has no open appointment to assign', p_ticket_id;
  end if;
  if v_appointment.technician_id is not null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyAssigned');
  end if;

  if v_ticket.address_id is not null then
    select * into v_addr from public.addresses where id = v_ticket.address_id;
  end if;

  -- Logic 1/2: rating-based reassignment, standard service tickets only.
  -- Unchanged by this migration.
  if not p_skip_rating_logic then
    select st2.id into v_prior_ticket_id
    from public.service_tickets st2
    where st2.customer_id = v_ticket.customer_id and st2.id <> p_ticket_id and st2.status = 'completed'
    order by st2.updated_at desc limit 1;

    if v_prior_ticket_id is not null then
      select sv.technician_id, r.stars into v_prior_tech_id, v_prior_stars
      from public.service_visits sv
      left join public.ratings r on r.visit_id = sv.id
      where sv.ticket_id = v_prior_ticket_id
      order by sv.timer_start desc limit 1;
    end if;

    if v_prior_stars >= 4 and v_prior_tech_id is not null then
      select t.id into v_tech_id
      from public.technicians t
      where t.id = v_prior_tech_id and t.org_id = p_org_id and t.is_active = true
        and exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      for update of t skip locked;
    elsif v_prior_stars is not null and v_prior_stars <= 3 then
      select t.id into v_tech_id
      from public.technicians t
      where t.org_id = p_org_id and t.is_active = true
        and exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      order by (
        select avg(r2.stars) from public.ratings r2
        join public.service_visits sv2 on sv2.id = r2.visit_id
        where sv2.technician_id = t.id
      ) desc nulls last
      for update of t skip locked
      limit 1;
    end if;
  end if;

  -- Candidate ranking: attendance-present (same-day/undated) / rostered
  -- (future-dated), hard filtered by capacity + is_active (skill is
  -- deliberately NOT a filter here — G1, restored), no open appointment,
  -- ordered by nearest last-known location, then fewest appointments
  -- already scheduled that day, then oldest technician record. Only runs
  -- when the rating logic above (if any) didn't already pick one.
  if v_tech_id is null then
    select t.id into v_tech_id
    from public.technicians t
    left join lateral (
      select tl.lat, tl.lng from public.technician_locations tl
      where tl.technician_id = t.id order by tl.recorded_at desc limit 1
    ) loc on true
    where t.org_id = p_org_id
      and t.is_active = true
      and (
        (v_appointment.scheduled_at is not null and v_appointment.scheduled_at::date > current_date)
        or exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
      )
      and (
        v_appointment.scheduled_at is null
        or v_appointment.scheduled_at::date <= current_date
        or not exists (
          select 1 from public.technician_availability ta
          where ta.technician_id = t.id
            and ta.date = v_appointment.scheduled_at::date
            and ta.status = 'leave'
        )
      )
      and not exists (
        select 1 from public.appointments a
        where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
      )
      and coalesce((
        select sum(st2.estimated_duration_minutes)
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = t.id
          and a2.status in ('scheduled', 'in_progress')
          and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ), 0) + coalesce(v_ticket.estimated_duration_minutes, 0) <= t.daily_capacity_minutes
    order by
      case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
        then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
        else null
      end asc nulls last,
      (
        select count(*) from public.appointments a2
        where a2.technician_id = t.id and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ) asc,
      t.created_at asc
    for update of t skip locked
    limit 1;
  end if;

  if v_tech_id is null then
    select count(*) into v_tech_count
    from public.technicians t
    where t.org_id = p_org_id and t.is_active = true
      and exists (
        select 1 from public.attendance a
        where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
          and a.check_in_at is not null and a.check_out_at is null
      );
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
      format('No free technician is available for ticket %s (%s checked in today).', p_ticket_id, v_tech_count), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  -- Logic 3: reset the SLA clock from the moment of assignment, not just
  -- ticket creation. Unchanged by this migration.
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = p_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$$;

create or replace function public._auto_assign_next_ticket_to_technician(
  p_org_id uuid,
  p_technician_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech technicians;
  v_appointment_id uuid;
  v_ticket_id uuid;
  v_ticket service_tickets;
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_tech from public.technicians where id = p_technician_id and org_id = p_org_id;
  if v_tech.id is null or not v_tech.is_active then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.technicianInactive');
  end if;

  -- Guard against a concurrent manual assign (or a second completion racing
  -- in) having already given this technician a job between their slot
  -- freeing up and this call running.
  if exists (
    select 1 from public.appointments a
    where a.technician_id = p_technician_id and a.status in ('scheduled', 'in_progress')
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyBusy');
  end if;

  -- Same attendance gate as _auto_assign_ticket_internal: don't hand new
  -- work to someone who has since checked out for the day.
  if not exists (
    select 1 from public.attendance a
    where a.technician_id = p_technician_id and a.org_id = p_org_id and a.date = current_date
      and a.check_in_at is not null and a.check_out_at is null
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.notPresent');
  end if;

  select a.id, a.ticket_id into v_appointment_id, v_ticket_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  left join public.addresses addr on addr.id = st.address_id
  left join lateral (
    select tl.lat, tl.lng from public.technician_locations tl
    where tl.technician_id = p_technician_id order by tl.recorded_at desc limit 1
  ) loc on true
  where a.org_id = p_org_id
    and a.technician_id is null
    and a.status in ('scheduled', 'in_progress')
    and st.status = 'open'
    and (a.scheduled_at is null or a.scheduled_at::date <= current_date)
    and coalesce((
      select sum(st2.estimated_duration_minutes)
      from public.appointments a2
      join public.service_tickets st2 on st2.id = a2.ticket_id
      where a2.technician_id = p_technician_id
        and a2.status in ('scheduled', 'in_progress')
        and a2.scheduled_at::date = coalesce(a.scheduled_at::date, current_date)
    ), 0) + coalesce(st.estimated_duration_minutes, 0) <= v_tech.daily_capacity_minutes
  order by
    case st.priority when 'very_urgent' then 0 when 'urgent' then 1 else 2 end asc,
    case when loc.lat is not null and addr.lat is not null and addr.lng is not null
      then point(loc.lng, loc.lat) <-> point(addr.lng, addr.lat)
      else null
    end asc nulls last,
    coalesce(a.scheduled_at, st.created_at) asc
  for update of a skip locked
  limit 1;

  if v_appointment_id is null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneWaiting');
  end if;

  update public.appointments set technician_id = p_technician_id where id = v_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_ticket_id;

  select * into v_ticket from public.service_tickets where id = v_ticket_id;
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', v_ticket_id), v_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id, 'appointment_id', v_appointment_id, 'ticket_id', v_ticket_id);
end;
$$;

-- Intentionally NOT re-granted on either function — same reasoning as prior
-- migrations: internal helpers only, create-or-replace preserves existing
-- grants (neither was ever granted to authenticated).

-- Backfill: re-run the backlog scan now, for every technician currently
-- checked in, so today's already-blocked tickets get picked up immediately
-- instead of waiting for the next check-in/completion event.
do $$
declare
  v_row record;
begin
  for v_row in
    select a.org_id, a.technician_id
    from public.attendance a
    where a.date = current_date
      and a.check_in_at is not null
      and a.check_out_at is null
  loop
    perform public._auto_assign_next_ticket_to_technician(v_row.org_id, v_row.technician_id);
  end loop;
end;
$$;
