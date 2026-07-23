-- Phase 2 of GV_Mart_Technician_Assignment_Logic_Change.md: hard filter the
-- candidate pool in _auto_assign_ticket_internal's DEFAULT RANKING block
-- (the spec explicitly scopes Phase 2 to this block only — the separate
-- Logic 1/2 rating-based preference picks above it are superseded by
-- Phase 3's unified weighted ranking, not touched here). No signature
-- change, so a plain create-or-replace is safe (unlike the Phase 1.5
-- appointment-availability-window migration, which had to drop+recreate
-- because it added parameters).
--
-- Filters added, all evaluated inside the existing candidate SELECT's WHERE
-- clause (spare-in-bag intentionally excluded — deferred, see below):
--   2. Availability: same-day appointments keep using today's is_on_duty
--      (unchanged). FUTURE-dated appointments now use the Phase-1
--      technician_availability roster instead — a technician's today
--      clock-in status is meaningless for a visit weeks/months out. No
--      availability row for that tech+date = no known exception = eligible
--      (permissive default, same reasoning as zone/skill below — the
--      roster table is brand new and mostly empty).
--   3. Zone match: technician.zone vs the ticket address's zone
--      (addresses.zone, added in Phase 1). PERMISSIVE WHEN UNKNOWN: only
--      excludes a technician when BOTH sides have a zone set AND they
--      differ. Almost no addresses/technicians have zone tagged yet as of
--      Phase 1's rollout, so a strict null-excludes-everyone filter would
--      break auto-assignment entirely today — confirmed with the project
--      owner rather than assumed.
--   4. Skill match: ticket.required_skill (auto-populated by Phase 1's
--      trigger from the product's category) vs technician.skills[].
--      PERMISSIVE WHEN THE TECHNICIAN HAS NO SKILLS TAGGED: an empty
--      skills array reads as "generalist / not yet tagged", not "qualified
--      for nothing" — also confirmed with the owner. Once a technician has
--      ANY skill tagged, they must include the ticket's required_skill.
--   7. Capacity: sum of estimated_duration_minutes for this technician's
--      other open appointments on the same date, plus this ticket's own
--      estimated_duration_minutes, must not exceed
--      technicians.daily_capacity_minutes. Legacy tickets from before
--      Phase 1 (estimated_duration_minutes still null) contribute 0 —
--      same permissive-when-unknown principle.
--
-- Deliberately NOT built (confirmed with the owner, not a silent gap):
--   5. Spare-in-bag — there is no data source today for "which spare part
--      will this job need" at assignment time; that's only decided during
--      the technician's on-site visit (OnSiteVisitPage's spares step).
--      Revisit once/if a required-parts-on-ticket concept exists.
--   1/6 (org_id match, no other open appointment) — already present,
--      unchanged.

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

  -- Logic 1/2: rating-based reassignment, standard service tickets only
  -- (AMC visit-scheduling loops pass p_skip_rating_logic => true and never
  -- reach this block). Unchanged in Phase 2 — see file header.
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
      where t.id = v_prior_tech_id and t.org_id = p_org_id and t.is_on_duty = true
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      for update of t skip locked;
    elsif v_prior_stars is not null and v_prior_stars <= 3 then
      select t.id into v_tech_id
      from public.technicians t
      where t.org_id = p_org_id and t.is_on_duty = true
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

  -- Candidate ranking: on-duty (same-day) / rostered (future-dated), hard
  -- filtered by zone + skill + capacity (Phase 2), no open appointment,
  -- ordered by nearest last-known location, then fewest appointments
  -- already scheduled that day, then oldest technician record. Only runs
  -- when the rating logic above (if any) didn't already pick a technician.
  if v_tech_id is null then
    select t.id into v_tech_id
    from public.technicians t
    left join lateral (
      select tl.lat, tl.lng from public.technician_locations tl
      where tl.technician_id = t.id order by tl.recorded_at desc limit 1
    ) loc on true
    where t.org_id = p_org_id
      and (
        v_appointment.scheduled_at is null
        or v_appointment.scheduled_at::date <= current_date
        or t.is_on_duty = true
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
      and (v_addr.zone is null or t.zone is null or t.zone = v_addr.zone)
      and (
        v_ticket.required_skill is null
        or t.skills = '{}'
        or v_ticket.required_skill = any(t.skills)
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
    select count(*) into v_tech_count from public.technicians where org_id = p_org_id and is_on_duty = true;
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
      format('No free technician is available for ticket %s (%s on-duty).', p_ticket_id, v_tech_count), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  -- Logic 3: reset the SLA clock from the moment of assignment, not just
  -- ticket creation. Unchanged in Phase 2.
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

-- Intentionally NOT re-granted: create-or-replace with an unchanged
-- signature preserves the existing grants (unlike Phase 1.5's drop+recreate
-- migration, which needed new grants because the parameter list changed).
-- This function was never granted to authenticated in the first place (see
-- 20260715215000's own note) — only called from other SECURITY DEFINER
-- functions.
