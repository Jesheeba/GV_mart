-- Rollback for 20261204110000_time_aware_customer_busy_check.sql.
-- Restores assign_ticket_technician's exact pre-change body (CR-tolerant
-- sha256 of the pre-change live body: 469dae2fc0211555056c720bfe9af164687f048d6c1ab27dd9ef63c670cf63be)
-- and drops the new _customer_conflict_appt helper. Purely additive/
-- subtractive -- nothing else in the schema is touched.

drop function if exists public._customer_conflict_appt(uuid, timestamp with time zone, integer, uuid);

create or replace function public.assign_ticket_technician(p_appointment_id uuid, p_technician_id uuid, p_force boolean DEFAULT false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  if v_ticket.product_id is null and v_ticket.unlisted_product_name is null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.productRequired');
  end if;

  if v_appointment.scheduled_at is not null and v_appointment.available_from is not null and v_appointment.available_to is not null then
    if exists (
      select 1
      from jsonb_array_elements(
        public._customer_exemption_blocks(v_org_id, v_ticket.customer_id, (v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date)
      ) as blk
      where (blk ->> 'start')::time < v_appointment.available_to
        and (blk ->> 'end')::time > v_appointment.available_from
    ) then
      return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.exemptionWindowConflict');
    end if;
  end if;

  -- conflict = another open appointment of this technician at an OVERLAPPING time (was: any open appointment)
  v_conflict_appt_id := public._tech_conflict_appt(p_technician_id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), p_appointment_id);

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
  set assigned_at = now(), sla_due_at = greatest(now(), coalesce(v_appointment.scheduled_at, now())) + v_sla_hours * interval '1 hour'
  where id = v_appointment.ticket_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$function$;

revoke all on function public.assign_ticket_technician(uuid, uuid, boolean) from public, anon;
grant execute on function public.assign_ticket_technician(uuid, uuid, boolean) to authenticated, service_role;
