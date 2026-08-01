-- Admin Settings / Attendance / Assignment / Booking audit, Task 5 — the
-- customer-app booking flow (book_service_ticket) was already rewritten in
-- 20260731170000_appointment_slots_and_stale_booking_followup.sql to stop
-- predicting technician availability from geometry and instead accept the
-- requested date unconditionally, try the real assignment engine once, and
-- let resolve_stale_bookings() escalate later if the day genuinely ends
-- with nobody assigned. create_complaint_ticket — the admin "New Complaint"
-- flow (NewComplaintPage.tsx) — was NOT touched by that fix and still ran
-- the old B1/B2/B3 geometry-only bump loop: it decided "narrow window ->
-- move to next day" purely from the customer's own marked-unavailable-
-- windows math against settings.work_start/work_end, without ever calling
-- _auto_assign_ticket_internal to check whether a technician was actually
-- free that day. Same bug as the one already fixed for the customer flow,
-- still live here.
--
-- Fix: apply the identical philosophy. This migration only touches the
-- B1/B2/B3 branch (p_appointment_mode = 'datetime' AND p_unavailable_windows
-- is not null) — the 'always' (anytime) mode path and the "legacy" plain
-- p_scheduled_at path (used when the caller doesn't pass unavailable
-- windows at all) are untouched, verbatim. The multi-window "customer said
-- they're unavailable X-Y" input stays and is still recorded into
-- appointment_unavailable_windows for staff visibility — it just no longer
-- drives a reschedule decision. resolve_stale_bookings() (already live,
-- already called from the customer dashboard, and channel-agnostic in its
-- own WHERE clause) picks up any admin-created booking that genuinely never
-- gets assigned, with no changes needed there.

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
  p_scheduled_at timestamptz,
  p_auto_assign boolean,
  p_available_from time default null,
  p_available_to time default null,
  p_unavailable_windows jsonb default null
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

  if p_appointment_mode is not null then
    if p_appointment_mode = 'datetime' and p_scheduled_at is not null and p_unavailable_windows is not null then
      -- Accept the requested date/time unconditionally — no geometry check,
      -- no bump loop. Real technician availability can't be reliably
      -- predicted ahead of time (a prior job may overrun), so this books
      -- the slot the admin actually asked for and lets the real assignment
      -- attempt below decide what happens next. If nobody is free right
      -- now, the ticket simply stays open/unassigned —
      -- resolve_stale_bookings() is what escalates it later if the day
      -- ends with no technician ever assigned.
      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
      values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled')
      returning id into v_appointment_id;

      if jsonb_array_length(coalesce(p_unavailable_windows, '[]'::jsonb)) > 0 then
        insert into public.appointment_unavailable_windows (org_id, appointment_id, start_time, end_time)
        select p_org_id, v_appointment_id, (elem ->> 'start')::time, (elem ->> 'end')::time
        from jsonb_array_elements(p_unavailable_windows) as elem;
      end if;

      if p_auto_assign then
        v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
      end if;
    else
      -- Legacy path — verbatim from 20260721091000.
      if p_appointment_mode = 'datetime' and p_scheduled_at is not null then
        if p_scheduled_at::time < v_settings.work_start or p_scheduled_at::time > v_settings.work_end then
          raise exception 'create_complaint_ticket: appointment time is outside working hours (% - %)', v_settings.work_start, v_settings.work_end;
        end if;
      end if;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status, available_from, available_to)
      values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled', p_available_from, p_available_to)
      returning id into v_appointment_id;
    end if;
  end if;

  if p_auto_assign and v_appointment_id is not null and v_assign_result is null then
    v_assign_result := public.auto_assign_ticket(v_ticket_id);
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
    'available_from', v_appointment_snapshot.available_from,
    'available_to', v_appointment_snapshot.available_to,
    'is_narrow_window', v_appointment_snapshot.is_narrow_window,
    'next_day_priority', v_appointment_snapshot.next_day_priority
  );
end;
$$;

grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean, time, time, jsonb
) to authenticated;
