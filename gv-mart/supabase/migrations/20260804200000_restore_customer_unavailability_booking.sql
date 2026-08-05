-- Change request (authorized 2026-08-04, after being flagged against the
-- v2.2 do-not-build scope guard and against the 2026-07-31 booking-audit fix
-- that removed this exact mechanism — see GV Mart memory
-- gv_mart_booking_audit_2026_07_31 and gv_mart_v22_scope_guard): restore the
-- customer-unavailability-window-driven booking geometry for the CUSTOMER
-- self-booking flow only (book_service_ticket), rebuilt with a redesigned
-- UI. The admin flow (create_complaint_ticket, NewComplaintPage.tsx) is
-- deliberately left on the appointment_slots system introduced 2026-07-31
-- and migrated onto by admin on 2026-08-03 — same scope boundary this
-- codebase has drawn between these two entry points before.
--
-- This is a restore, not a new build: `_largest_free_window`,
-- `_customer_exemption_blocks`, and `appointment_unavailable_windows` (all
-- from 20260723100000_step4_booking_model_schema.sql) were never dropped —
-- only book_service_ticket's use of them was removed. The body below is
-- ported verbatim from the last live geometry version
-- (20260723101000_step4_booking_rpcs.sql, with the
-- 20260731100000_fix_scheduled_at_timezone.sql `at time zone 'Asia/Kolkata'`
-- fix already folded in), adapted for the current simpler signature: a
-- plain `p_scheduled_date date` (the "Anytime" appointment_mode was already
-- removed from this screen before 07-31 and stays removed) plus
-- `p_unavailable_windows` in place of `p_slot_id`. The IST past-date guard
-- from 20260803150000 is preserved.
--
-- Known, accepted tradeoff (explicitly re-confirmed with the requester):
-- this reintroduces the original bug shape this system was once responsible
-- for — a customer's own tapped-unavailable geometry, not real technician
-- availability, decides whether a date bumps to the next day. Admin-created
-- bookings are unaffected (still slot-based, still unconditionally
-- accepted).

drop function if exists public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, date, uuid
);

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
  p_unavailable_windows jsonb default '[]'::jsonb
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
  v_estimated_minutes integer;
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
  -- IST-aware "today" (see 20260731100000_fix_scheduled_at_timezone.sql).
  if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'book_service_ticket: scheduled date cannot be in the past';
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
  returning id, estimated_duration_minutes into v_ticket_id, v_estimated_minutes;

  -- B1/B2/B3 geometry path (see file header) — always engaged now that this
  -- RPC only ever books 'datetime' appointments.
  v_target_date := p_scheduled_date;
  v_bumped := false;
  v_attempt := 0;

  insert into public.appointments (org_id, ticket_id, mode, status)
  values (p_org_id, v_ticket_id, 'datetime', 'scheduled')
  returning id into v_appointment_id;

  loop
    v_attempt := v_attempt + 1;
    v_blocked := coalesce(p_unavailable_windows, '[]'::jsonb)
      || public._customer_exemption_blocks(p_org_id, v_customer_id, v_target_date);
    v_window := public._largest_free_window(v_settings.work_start, v_settings.work_end, v_blocked);
    v_window_minutes := coalesce((v_window ->> 'minutes')::integer, 0);
    v_avail_from := (v_window ->> 'available_from')::time;
    v_avail_to := (v_window ->> 'available_to')::time;
    -- B2: narrow guard — a narrow window is still OK if it's >= the job's
    -- own estimated duration; only a narrow window shorter than the job
    -- itself blocks booking.
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

      v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
      exit when coalesce((v_assign_result ->> 'assigned')::boolean, false);
      exit when v_attempt >= 2 or (v_assign_result ->> 'reason_key') is distinct from 'service.assign.noneAvailable';
    elsif v_attempt >= 2 then
      -- B3's next-day bump also failed to find any window (fully blocked
      -- both days) — force-book and flag ops for manual assignment.
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
        format('Customer-marked unavailable windows leave no bookable slot for ticket %s even after moving to the next day.', v_ticket_id),
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
    'available_from', v_appointment_snapshot.available_from,
    'available_to', v_appointment_snapshot.available_to,
    'is_narrow_window', v_appointment_snapshot.is_narrow_window,
    'next_day_priority', v_appointment_snapshot.next_day_priority
  );
end;
$$;

grant execute on function public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, date, jsonb
) to authenticated;

-- ── resolve_stale_bookings ──────────────────────────────────────────────
-- Was purely slot-based (max active appointment_slots.end_time). Customer
-- geometry bookings have no slot_id — branch per-appointment: slot-based
-- (admin bookings) keep using the slot's own end_time; geometry bookings
-- (customer, slot_id null) use their own available_to, falling back to
-- settings.work_end for the rare fully-blocked/force-booked case where
-- available_to itself is null. Same signature — plain create or replace.
create or replace function public.resolve_stale_bookings(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_local timestamp;
  v_work_end time;
  v_count integer := 0;
  v_appt record;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'resolve_stale_bookings: org mismatch';
  end if;

  v_now_local := now() at time zone 'Asia/Kolkata';
  select work_end into v_work_end from public.settings where org_id = p_org_id;

  for v_appt in
    select a.id as appointment_id, a.ticket_id
    from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    left join public.appointment_slots s on s.id = a.slot_id
    where a.org_id = p_org_id
      and a.follow_up_flagged_at is null
      and a.technician_id is null
      and a.status = 'scheduled'
      and st.status = 'open'
      and (
        (a.scheduled_at at time zone 'Asia/Kolkata')::date < v_now_local::date
        or (
          (a.scheduled_at at time zone 'Asia/Kolkata')::date = v_now_local::date
          and v_now_local::time > coalesce(s.end_time, a.available_to, v_work_end)
        )
      )
  loop
    update public.appointments set follow_up_flagged_at = now() where id = v_appt.appointment_id;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    select p_org_id, r, 'booking_needs_followup', 'Booking needs manual follow-up',
      format('Ticket %s was not assigned a technician today — call the customer to confirm a priority slot.', v_appt.ticket_id),
      v_appt.ticket_id
    from unnest(array['master', 'operation_admin', 'sales_admin']::user_role[]) as r;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.resolve_stale_bookings(uuid) to authenticated;
