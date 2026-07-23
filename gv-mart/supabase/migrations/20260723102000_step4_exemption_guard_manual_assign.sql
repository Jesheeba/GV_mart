-- B4 (exemption windows), continued: book_service_ticket/create_complaint_
-- ticket (20260723101000) already keep exemption time out of the derived
-- available window for anything booked through them, so assignment never
-- lands there via the normal path. The one other place a technician gets
-- bound to an appointment is the admin's manual/drag-drop picker,
-- assign_ticket_technician — the "Admin-side requirement" fast-allocation
-- path the assignment spec calls out explicitly, and the scenario B4's own
-- wording ("no technician may be assigned... even if a technician is free")
-- most obviously describes: an admin dragging a free technician onto a slot
-- that happens to fall inside a customer's exemption window. Guarded here.
--
-- Deliberately NOT touching public._auto_assign_ticket_internal (STEP 3
-- owns it this round) — this migration only redefines
-- assign_ticket_technician, a distinct function with an unchanged
-- signature, so create-or-replace is safe (same as
-- 20260721110000's g1 fix) and existing grants persist automatically.
--
-- The check is intentionally NOT skippable by p_force — every other
-- conflict this function checks (technician busy, customer busy) is a
-- scheduling optimisation an admin may knowingly override; an exemption
-- window is a hard customer constraint ("no technician here, period"), so
-- force must not bypass it. Only fires when the appointment actually
-- carries a real window (scheduled_at + available_from/to all set) — an
-- 'always'-mode or window-less appointment has no time slot to check an
-- exemption against, so it's left alone (a known, documented gap — see
-- this task's final report).
--
-- Body is otherwise verbatim from 20260715215000 (diffed before writing).

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

  -- B4: exemption-window hard block — checked before anything else,
  -- including force, so it can't be bypassed like the busy-conflicts below.
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

  -- v2.2 §6.4: "one person can't have two open appointments" — surfaced as a
  -- conflict the caller can inspect/force past rather than a bare DB error.
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

  -- BuildSpec ADM-11: "no two simultaneous appointments per customer" —
  -- block assigning a second technician to the same customer while another
  -- of that customer's tickets already has an open appointment (regardless
  -- of technician), unless forced.
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

  -- Forced reassignment: bump whoever currently holds that technician's open
  -- slot back to unassigned so the unique index never trips.
  if p_force and v_conflict_appt_id is not null then
    update public.appointments set technician_id = null where id = v_conflict_appt_id;
    update public.service_tickets st set status = 'open'
      from public.appointments a where a.id = v_conflict_appt_id and st.id = a.ticket_id;
  end if;

  update public.appointments set technician_id = p_technician_id where id = p_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_appointment.ticket_id and status = 'open';

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_org_id, p.id, 'appointment_assigned', 'Job assigned', format('Ticket %s assigned to you.', v_appointment.ticket_id), p_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  -- Logic 3: manual assign / drag-to-reassign also resets the SLA clock,
  -- same settings-lookup + case pattern as the auto-assign engine. Not
  -- gated on the ticket's prior status (unlike the status='assigned'
  -- update above) — a forced reassignment of an already-assigned ticket
  -- should still reset the clock.
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

-- Intentionally NOT re-granted — unchanged signature, create-or-replace
-- preserves existing grants (same reasoning as 20260721110000).
