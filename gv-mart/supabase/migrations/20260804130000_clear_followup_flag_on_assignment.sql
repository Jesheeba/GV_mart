-- Fix: a completed service ticket still shows the customer app's "technician
-- couldn't visit today, priority tomorrow" banner.
--
-- Root cause (confirmed live against production data): resolve_stale_bookings
-- (20260731170000) sets appointments.follow_up_flagged_at once, the day a
-- booking ends with no technician assigned. The customer app's needsFollowUp
-- badge (CustomerBookingsPage/CustomerBookingDetailPage) reads that column
-- directly with no status check. But nothing ever clears the column back to
-- null once the appointment is later assigned and the job completed — so the
-- "come back tomorrow" notice sticks around forever. Verified: 3 completed,
-- fully-serviced tickets in prod still carry a stale follow_up_flagged_at.
--
-- Fix: clear follow_up_flagged_at whenever an appointment actually receives a
-- technician — the auto-assign engine (both entry points) and the admin's
-- manual/drag-drop assign_ticket_technician. Once a technician is bound to
-- the appointment, the "needs manual follow-up call" state is resolved,
-- regardless of what happens to the job afterwards. Bodies are otherwise
-- verbatim from the currently-live versions (20260803090000 and
-- 20260723102000) — only the one column added to each technician_id update.

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

  update public.appointments set technician_id = v_tech_id, follow_up_flagged_at = null where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

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

  if exists (
    select 1 from public.appointments a
    where a.technician_id = p_technician_id and a.status in ('scheduled', 'in_progress')
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyBusy');
  end if;

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

  update public.appointments set technician_id = p_technician_id, follow_up_flagged_at = null where id = v_appointment_id;
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

create or replace function public.assign_ticket_technician(
  p_appointment_id uuid,
  p_technician_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_appointment appointments;
  v_ticket service_tickets;
  v_conflict_appt_id uuid;
  v_customer_conflict_id uuid;
  v_settings settings;
  v_sla_hours numeric;
begin
  if not public.is_ops_staff() then
    raise exception 'assign_ticket_technician: only master or operation_admin may assign';
  end if;

  select * into v_appointment from public.appointments where id = p_appointment_id;
  if v_appointment.id is null then
    raise exception 'assign_ticket_technician: appointment % not found', p_appointment_id;
  end if;
  v_org_id := v_appointment.org_id;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'assign_ticket_technician: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = v_org_id) then
    raise exception 'assign_ticket_technician: technician % not found', p_technician_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_appointment.ticket_id;

  if v_appointment.scheduled_at is not null and v_appointment.available_from is not null and v_appointment.available_to is not null then
    if exists (
      select 1
      from jsonb_array_elements(
        public._customer_exemption_blocks(v_org_id, v_ticket.customer_id, v_appointment.scheduled_at::date)
      ) as blk
      where (blk ->> 'start')::time < v_appointment.available_to
        and (blk ->> 'end')::time > v_appointment.available_from
    ) then
      return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.exemptionWindowConflict');
    end if;
  end if;

  select a.id into v_conflict_appt_id
  from public.appointments a
  where a.technician_id = p_technician_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id;

  if v_conflict_appt_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.technicianBusy', 'conflict_appointment_id', v_conflict_appt_id
    );
  end if;

  select a.id into v_customer_conflict_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  where st.customer_id = v_ticket.customer_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id
    and st.id <> v_ticket.id;

  if v_customer_conflict_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.customerBusy', 'conflict_appointment_id', v_customer_conflict_id
    );
  end if;

  if p_force and v_conflict_appt_id is not null then
    update public.appointments set technician_id = null where id = v_conflict_appt_id;
    update public.service_tickets st set status = 'open'
      from public.appointments a where a.id = v_conflict_appt_id and st.id = a.ticket_id;
  end if;

  update public.appointments set technician_id = p_technician_id, follow_up_flagged_at = null where id = p_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_appointment.ticket_id and status = 'open';

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_org_id, p.id, 'appointment_assigned', 'Job assigned', format('Ticket %s assigned to you.', v_appointment.ticket_id), p_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  select * into v_settings from public.settings where org_id = v_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_appointment.ticket_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$$;

-- Intentionally NOT re-granted on any of the three — same reasoning as prior
-- migrations touching these functions: unchanged signatures, create-or-
-- replace preserves existing grants.

-- Backfill: clear the stale flag on every appointment that has already been
-- resolved (technician bound) but still carries the old banner, so existing
-- completed/in-flight jobs stop showing "couldn't visit today" immediately
-- instead of waiting for their next assignment event (which, for a completed
-- ticket, will never happen).
update public.appointments
set follow_up_flagged_at = null
where follow_up_flagged_at is not null
  and technician_id is not null;
