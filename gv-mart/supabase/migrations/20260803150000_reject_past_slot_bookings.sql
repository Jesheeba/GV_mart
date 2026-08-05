-- Bug: booking today's date still offered/accepted an already-passed slot
-- (e.g. picking "Morning 08:00-12:00" at 6pm) — neither the customer's
-- book_service_ticket nor the admin's create_complaint_ticket ever checked
-- the chosen slot's end_time against the current Asia/Kolkata clock, only
-- that the DATE itself wasn't in the past. The frontend (BookServicePage.tsx
-- / NewComplaintPage.tsx) now filters passed slots out of today's grid, but
-- the RPC is the actual source of truth — this closes the same gap
-- server-side (defense in depth: a customer could sit on the booking screen
-- past a slot's end time before submitting). Same-signature change for both
-- functions — plain create or replace, no drop needed.

create or replace function public.book_service_ticket(
  p_org_id uuid,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_scheduled_date date,
  p_slot_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_settings settings;
  v_detected jsonb;
  v_type ticket_type;
  v_sla_hours numeric;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_lead_id uuid;
  v_assign_result jsonb;
  v_slot appointment_slots;
  v_appointment_snapshot appointments;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'book_service_ticket: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'book_service_ticket: org mismatch';
  end if;
  if p_name_of_complaint is null or btrim(p_name_of_complaint) = '' then
    raise exception 'book_service_ticket: issue description is required';
  end if;
  if p_address_id is not null and not exists (
    select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id
  ) then
    raise exception 'book_service_ticket: address % does not belong to this customer', p_address_id;
  end if;
  -- IST-aware "today", not the session's UTC current_date (see
  -- 20260731100000_fix_scheduled_at_timezone.sql for why this distinction
  -- matters this close to midnight).
  if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'book_service_ticket: scheduled date cannot be in the past';
  end if;

  select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
  if v_slot.id is null then
    raise exception 'book_service_ticket: slot % not found or inactive', p_slot_id;
  end if;

  -- New: today's date is still >= today, but a slot whose window has
  -- already fully elapsed (e.g. Morning at 6pm) can't be booked either.
  if p_scheduled_date = (now() at time zone 'Asia/Kolkata')::date
     and v_slot.end_time <= (now() at time zone 'Asia/Kolkata')::time then
    raise exception 'book_service_ticket: slot % has already ended for today', p_slot_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'book_service_ticket: no settings row for org %', p_org_id;
  end if;

  v_detected := public._detect_ticket_type(p_org_id, v_customer_id, p_product_id);
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
    p_org_id, v_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', 'customer_app',
    now() + v_sla_hours * interval '1 hour'
  )
  returning id into v_ticket_id;

  -- Accept the requested date+slot unconditionally — no geometry check, no
  -- bump loop. Real technician availability can't be reliably predicted
  -- ahead of time (a prior job may overrun), so this books the slot the
  -- customer actually asked for and lets the real assignment attempt below
  -- decide what happens next. If nobody is free right now, the ticket
  -- simply stays open/unassigned — resolve_stale_bookings() (below) is what
  -- escalates it later if the day ends with no technician ever assigned.
  insert into public.appointments (org_id, ticket_id, mode, scheduled_at, slot_id, status)
  values (p_org_id, v_ticket_id, 'datetime', (p_scheduled_date + v_slot.start_time) at time zone 'Asia/Kolkata', p_slot_id, 'scheduled')
  returning id into v_appointment_id;

  v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);

  if p_product_id is null then
    v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

    if v_lead_id is null then
      insert into public.leads (org_id, customer_id, name, mobile, source, kind, status)
      select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', 'service', 'new'
      from public.customers c where c.id = v_customer_id
      returning id into v_lead_id;
    end if;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'service_enquiry', p_name_of_complaint);
  end if;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'service_booked', 'New service booking from customer app',
    format('%s', p_name_of_complaint), v_ticket_id
  );

  select * into v_appointment_snapshot from public.appointments where id = v_appointment_id;

  return jsonb_build_object(
    'ticket_id', v_ticket_id, 'appointment_id', v_appointment_id,
    'detected_type', v_detected, 'lead_id', v_lead_id, 'assign_result', v_assign_result,
    'scheduled_at', v_appointment_snapshot.scheduled_at,
    'slot_id', v_slot.id, 'slot_name', v_slot.name,
    'slot_start_time', v_slot.start_time, 'slot_end_time', v_slot.end_time
  );
end;
$$;

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

    -- Same date-in-the-past guard as book_service_ticket, IST-aware.
    if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
      raise exception 'create_complaint_ticket: scheduled date cannot be in the past';
    end if;

    select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
    if v_slot.id is null then
      raise exception 'create_complaint_ticket: slot % not found or inactive', p_slot_id;
    end if;

    -- New: today's date is still >= today, but a slot whose window has
    -- already fully elapsed (e.g. Morning at 6pm) can't be booked either.
    if p_scheduled_date = (now() at time zone 'Asia/Kolkata')::date
       and v_slot.end_time <= (now() at time zone 'Asia/Kolkata')::time then
      raise exception 'create_complaint_ticket: slot % has already ended for today', p_slot_id;
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
