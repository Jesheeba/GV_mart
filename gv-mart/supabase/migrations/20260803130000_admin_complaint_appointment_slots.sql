-- Admin "New Complaint" appointment step (NewComplaintPage.tsx) still used
-- the old free-text time-window builder (windowMode any/custom + per-window
-- chips + exemption-window preview) that the Customer Dashboard Booking
-- Audit (2026-07-31) already replaced on the customer side with a plain
-- date + admin-configured appointment slot (see
-- 20260731170000_appointment_slots_and_stale_booking_followup.sql). That
-- nested chip/time-input UI was also overflowing its Card on narrow admin
-- viewports. Fix: finish the migration for the admin flow too, so both
-- surfaces share one booking format — create_complaint_ticket now takes
-- p_scheduled_date + p_slot_id instead of
-- p_scheduled_at/p_available_from/p_available_to/p_unavailable_windows,
-- mirroring book_service_ticket. Signature change — not append-only — so
-- DROP is required; NewComplaintPage.tsx is the only caller.
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean, time, time, jsonb
);

create or replace function public.create_complaint_ticket(
  p_org_id uuid,
  p_customer_id uuid,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_channel ticket_channel,
  p_appointment_mode appointment_mode,
  p_auto_assign boolean,
  p_scheduled_date date default null,
  p_slot_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings settings;
  v_detected jsonb;
  v_type ticket_type;
  v_sla_hours numeric;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_assign_result jsonb;
  v_slot appointment_slots;
  v_appointment_snapshot appointments;
begin
  if not public.is_ops_staff() then
    raise exception 'create_complaint_ticket: only master or operation_admin may raise a ticket';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_complaint_ticket: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_complaint_ticket: customer % not found', p_customer_id;
  end if;
  if p_name_of_complaint is null or btrim(p_name_of_complaint) = '' then
    raise exception 'create_complaint_ticket: name_of_complaint is required';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_complaint_ticket: no settings row for org %', p_org_id;
  end if;

  v_detected := public._detect_ticket_type(p_org_id, p_customer_id, p_product_id);
  v_type := (v_detected ->> 'type')::ticket_type;

  v_sla_hours := case p_priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, brand_id, model_id,
    name_of_complaint, nature_of_complaint, type, priority, status, channel, sla_due_at
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour'
  )
  returning id into v_ticket_id;

  if p_appointment_mode = 'datetime' then
    if p_scheduled_date is null or p_slot_id is null then
      raise exception 'create_complaint_ticket: scheduled date and slot are required for a datetime appointment';
    end if;

    select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
    if v_slot.id is null then
      raise exception 'create_complaint_ticket: slot % not found or inactive', p_slot_id;
    end if;

    -- Same philosophy as book_service_ticket (customer flow, fixed
    -- 2026-07-31): accept the requested date+slot unconditionally — real
    -- technician availability can't be reliably predicted ahead of time —
    -- try the real assignment engine once, and let resolve_stale_bookings()
    -- escalate later if the day genuinely ends with nobody assigned.
    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, slot_id, status)
    values (p_org_id, v_ticket_id, 'datetime', (p_scheduled_date + v_slot.start_time) at time zone 'Asia/Kolkata', p_slot_id, 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
    end if;
  elsif p_appointment_mode = 'always' then
    insert into public.appointments (org_id, ticket_id, mode, status)
    values (p_org_id, v_ticket_id, 'always', 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public.auto_assign_ticket(v_ticket_id);
    end if;
  end if;

  if v_appointment_id is not null then
    select * into v_appointment_snapshot from public.appointments where id = v_appointment_id;
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'appointment_id', v_appointment_id,
    'detected_type', v_detected,
    'assign_result', v_assign_result,
    'scheduled_at', v_appointment_snapshot.scheduled_at,
    'slot_id', v_appointment_snapshot.slot_id,
    'slot_name', v_slot.name,
    'slot_start_time', v_slot.start_time,
    'slot_end_time', v_slot.end_time
  );
end;
$$;

grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid
) to authenticated;
