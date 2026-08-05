-- Fix: an interrupted earlier push of 20260804170000 applied a draft of
-- create_complaint_ticket that replaced the 15th parameter
-- (p_referred_by_technician_id uuid) with p_unlisted_product_name text at
-- the same position, instead of appending it as a 16th trailing param.
-- Postgres's CREATE OR REPLACE FUNCTION only "replaces" when the full
-- parameter type list is unchanged — changing a trailing param's type
-- creates a second, distinct overload alongside the original rather than
-- erroring, and PostgREST's OpenAPI introspection confirmed exactly that: a
-- create_complaint_ticket(...) missing p_referred_by_technician_id
-- entirely, silently breaking the 2026-08-04 referral-capture feature for
-- ops-created tickets.
--
-- Fix: drop the erroneous accidental overload explicitly, then re-create
-- the correct function with BOTH params — p_referred_by_technician_id
-- (uuid, restoring the referral capture) and p_unlisted_product_name (text,
-- the actual new feature) as two separate trailing params, matching what
-- 20260804170000's file now contains after being corrected in place.

drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, text
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
  p_slot_id uuid default null,
  p_referred_by_technician_id uuid default null,
  p_unlisted_product_name text default null
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
  v_lead_id uuid; -- REFERRAL: resolved technician referral, if any
  v_customer_name text;
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

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Service customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Service ticket, referred by technician');
  end if;

  v_detected := public._detect_ticket_type(p_org_id, p_customer_id, p_product_id);
  v_type := (v_detected ->> 'type')::ticket_type;

  v_sla_hours := case p_priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, brand_id, model_id, unlisted_product_name,
    name_of_complaint, nature_of_complaint, type, priority, status, channel, sla_due_at, lead_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id, nullif(btrim(coalesce(p_unlisted_product_name, '')), ''),
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour', v_lead_id
  )
  returning id into v_ticket_id;

  if p_appointment_mode = 'datetime' then
    if p_scheduled_date is null or p_slot_id is null then
      raise exception 'create_complaint_ticket: scheduled date and slot are required for a datetime appointment';
    end if;

    if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
      raise exception 'create_complaint_ticket: scheduled date cannot be in the past';
    end if;

    select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
    if v_slot.id is null then
      raise exception 'create_complaint_ticket: slot % not found or inactive', p_slot_id;
    end if;

    if p_scheduled_date = (now() at time zone 'Asia/Kolkata')::date
       and v_slot.end_time <= (now() at time zone 'Asia/Kolkata')::time then
      raise exception 'create_complaint_ticket: slot % has already ended for today', p_slot_id;
    end if;

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
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text
) to authenticated;
