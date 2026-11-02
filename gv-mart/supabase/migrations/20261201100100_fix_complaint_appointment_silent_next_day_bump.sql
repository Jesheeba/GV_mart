-- Urgent item 4 (2026-11-02) -- master-created complaint silently scheduled for
-- the day AFTER the one picked in "New Complaint" (e.g. picked 2/11, stored/
-- shown as 3/11), even though the picked date's own working-hours window was
-- completely open.
--
-- ROOT CAUSE (verified by reading, not guessing):
-- _create_complaint_ticket_internal's 'datetime' + p_unavailable_windows
-- branch (live in 20261024160000_admin_complaint_unavailable_windows.sql,
-- copied byte-for-byte from book_service_ticket's identical loop,
-- 20260731100000/20260804200000) runs a retry loop meant for ONE thing only:
-- "the picked day is fully blocked by the customer's own marked unavailable
-- windows, so try the next day instead" (the B3 design, see that migration's
-- header). But the loop's exit conditions also fall through to the SAME
-- v_target_date := v_target_date + 1 bump whenever auto-assignment merely
-- fails to find a free technician right now
-- (_auto_assign_ticket_internal returning reason_key =
-- 'service.assign.noneAvailable') -- a staffing/capacity fact that has
-- NOTHING to do with whether the picked date's work-hours window is open.
--
-- Concretely: attempt 1 is geometrically fine (v_geometrically_ok = true,
-- the normal case -- no customer-marked unavailable windows), so the
-- appointment IS written at the master's picked date first. If
-- auto_assign is on (the admin form's default) and no technician happens to
-- be free at that exact moment -- extremely common, since "free right now"
-- depends on every other technician's live schedule, not on the calendar
-- date -- the loop does NOT exit; it falls through to
-- `v_target_date := v_target_date + 1; v_bumped := true;`, loops a second
-- time, and -- because the SAME day is still geometrically open on attempt
-- 2 -- immediately overwrites the appointment's scheduled_at to
-- picked_date + 1 and unconditionally exits (attempt >= 2), regardless of
-- whether the second auto-assign attempt actually succeeded. The master's
-- chosen date is silently discarded even though it was never actually
-- unbookable.
--
-- This is a pure control-flow bug, not a timezone-cast bug: every
-- `(date + time) at time zone 'Asia/Kolkata'` construction in this function
-- is already correct (fixed in 20260731100000, re-swept in
-- 20261006170000), and the frontend (NewComplaintPage.tsx -> service.ts's
-- createComplaintTicket) already sends a plain "YYYY-MM-DD" date string with
-- no UTC-midnight/`new Date(...).toISOString()` round-trip to corrupt.
-- Reproducing with TZ=UTC/Asia/Kolkata/America/Los_Angeles and at 00:30/23:30
-- IST (see src/lib/ist.test.ts and src/services/service.schedulingDate.test.ts
-- added alongside this migration) confirms the write path is TZ-safe; the
-- failure is 100% reproducible in plpgsql regardless of session timezone
-- whenever _auto_assign_ticket_internal returns
-- reason_key = 'service.assign.noneAvailable' on the first attempt.
--
-- FIX: once a day is geometrically bookable, commit to it and stop -- a
-- failed (or skipped) auto-assign attempt no longer feeds back into the
-- day-bump loop. _auto_assign_ticket_internal already raises its own
-- 'ticket_unassigned' notification when it can't find a technician, so ops
-- still gets paged for manual assignment; the ticket just keeps the date the
-- master actually chose instead of silently moving it. The B3 bump
-- (`elsif v_attempt >= 2`) is untouched -- it still exists purely for a day
-- that is ITSELF fully blocked by the customer's own marked unavailable
-- windows, which is the only case this loop was ever meant to bump for.
--
-- Scope: this migration only touches create_complaint_ticket /
-- _create_complaint_ticket_internal (the admin "New Complaint" path --
-- urgent item 4). book_service_ticket (customer self-booking) has the
-- IDENTICAL bug in the identical loop -- see the handoff report's finding 8
-- -- and is deliberately left untouched here to keep this fix narrowly
-- scoped and reviewable; it needs the same one-line fix in a follow-up once
-- this is approved.
--
-- Body below is copied verbatim from the live
-- 20261024160000_admin_complaint_unavailable_windows.sql definitions, with
-- ONLY the loop's exit/bump control flow changed as described above --
-- nothing else (params, geometry math, notification text, return shape) is
-- altered.

create or replace function public._create_complaint_ticket_internal(
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
  p_unlisted_product_name text default null,
  p_complaint_type_id uuid default null,
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
  v_estimated_minutes integer;
  v_appointment_id uuid;
  v_assign_result jsonb;
  v_slot appointment_slots;
  v_appointment_snapshot appointments;
  v_lead_id uuid; -- REFERRAL: resolved technician referral, if any
  v_customer_name text;
  v_target_date date;
  v_bumped boolean;
  v_attempt integer;
  v_blocked jsonb;
  v_window jsonb;
  v_avail_from time;
  v_avail_to time;
  v_window_minutes integer;
  v_is_narrow boolean;
  v_geometrically_ok boolean;
begin
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
    name_of_complaint, nature_of_complaint, complaint_type_id, type, priority, status, channel, sla_due_at, lead_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id, nullif(btrim(coalesce(p_unlisted_product_name, '')), ''),
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), p_complaint_type_id, v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour', v_lead_id
  )
  returning id, estimated_duration_minutes into v_ticket_id, v_estimated_minutes;

  if p_appointment_mode = 'datetime' then
    if p_scheduled_date is null then
      raise exception 'create_complaint_ticket: scheduled date is required for a datetime appointment';
    end if;

    if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
      raise exception 'create_complaint_ticket: scheduled date cannot be in the past';
    end if;

    if p_unavailable_windows is not null then
      -- Customer-app parity (2026-10-24) — free-form unavailable-time-range
      -- booking, same largest-free-window geometry scan as
      -- book_service_ticket, instead of the fixed slot picker below.
      v_target_date := p_scheduled_date;
      v_bumped := false;
      v_attempt := 0;

      insert into public.appointments (org_id, ticket_id, mode, status)
      values (p_org_id, v_ticket_id, 'datetime', 'scheduled')
      returning id into v_appointment_id;

      loop
        v_attempt := v_attempt + 1;
        v_blocked := coalesce(p_unavailable_windows, '[]'::jsonb)
          || public._customer_exemption_blocks(p_org_id, p_customer_id, v_target_date);
        v_window := public._largest_free_window(v_settings.work_start, v_settings.work_end, v_blocked);
        v_window_minutes := coalesce((v_window ->> 'minutes')::integer, 0);
        v_avail_from := (v_window ->> 'available_from')::time;
        v_avail_to := (v_window ->> 'available_to')::time;
        v_is_narrow := v_avail_from is not null and v_window_minutes <= v_settings.narrow_window_threshold_minutes;
        v_geometrically_ok := v_avail_from is not null
          and (not v_is_narrow or v_window_minutes >= coalesce(v_estimated_minutes, 0));

        if v_geometrically_ok then
          update public.appointments
          set scheduled_at = (v_target_date + v_avail_from) at time zone 'Asia/Kolkata',
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = v_is_narrow,
              next_day_priority = v_bumped,
              rescheduled_from_date = case when v_bumped then p_scheduled_date else null end
          where id = v_appointment_id;

          -- Urgent item 4 fix: a geometrically bookable day is FINAL. Whether
          -- or not a technician could be auto-assigned to it right now is a
          -- staffing/capacity question, never a reason to silently move the
          -- date the master picked — _auto_assign_ticket_internal already
          -- raises its own 'ticket_unassigned' notification for ops when it
          -- can't find anyone, so nothing is lost by stopping here.
          if p_auto_assign then
            v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
          end if;
          exit;
        elsif v_attempt >= 2 then
          -- Fully blocked both days — force-book and flag ops for manual assignment.
          update public.appointments
          set scheduled_at = (v_target_date + coalesce(v_avail_from, v_settings.work_start)) at time zone 'Asia/Kolkata',
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = true,
              next_day_priority = true,
              rescheduled_from_date = p_scheduled_date
          where id = v_appointment_id;

          insert into public.notifications (org_id, role, type, title, body, ref_id)
          values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
            format('Marked unavailable windows leave no bookable slot for ticket %s even after moving to the next day.', v_ticket_id),
            v_ticket_id);
          exit;
        end if;

        v_target_date := v_target_date + 1;
        v_bumped := true;
      end loop;

      if jsonb_array_length(coalesce(p_unavailable_windows, '[]'::jsonb)) > 0 then
        insert into public.appointment_unavailable_windows (org_id, appointment_id, start_time, end_time)
        select p_org_id, v_appointment_id, (elem ->> 'start')::time, (elem ->> 'end')::time
        from jsonb_array_elements(p_unavailable_windows) as elem;
      end if;
    else
      if p_slot_id is null then
        raise exception 'create_complaint_ticket: scheduled date and slot are required for a datetime appointment';
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
    'slot_end_time', v_slot.end_time,
    'available_from', v_appointment_snapshot.available_from,
    'available_to', v_appointment_snapshot.available_to,
    'is_narrow_window', v_appointment_snapshot.is_narrow_window,
    'next_day_priority', v_appointment_snapshot.next_day_priority
  );
end;
$$;

-- create_complaint_ticket itself is an unchanged thin wrapper (same 18
-- params, same body) -- CREATE OR REPLACE in place is enough here since the
-- param list is byte-for-byte identical to the live overload, so no
-- drop-then-create / grant dance is needed this time.
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
  p_unlisted_product_name text default null,
  p_complaint_type_id uuid default null,
  p_unavailable_windows jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_ops_staff() then
    raise exception 'create_complaint_ticket: only master or operation_admin may raise a ticket';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_complaint_ticket: org mismatch';
  end if;

  return public._create_complaint_ticket_internal(
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, p_nature_of_complaint, p_priority, p_channel, p_appointment_mode, p_auto_assign,
    p_scheduled_date, p_slot_id, p_referred_by_technician_id, p_unlisted_product_name, p_complaint_type_id,
    p_unavailable_windows
  );
end;
$$;
