-- A customer service booking with no product selected blocks auto-assignment
-- entirely (see 20260804170000_gate_assignment_on_product.sql's
-- `service.assign.productRequired` gate) until a staff member manually fills
-- in a product on the ticket. Until now the only way to discover this was
-- the Tickets page's "Missing product" filter chip
-- (TicketsListPage.tsx isMissingProductRow) -- nothing ever proactively
-- notified anyone, and even that chip only reaches whoever happens to open
-- the Tickets page.
--
-- Add an explicit notification, fired once at booking time (not from inside
-- _auto_assign_ticket_internal, which can be retried multiple times against
-- the same still-unassigned ticket via the check-in/completion backlog scan
-- -- firing there would spam a fresh notification on every retry). Reaches
-- both operation_admin (works the ticket queue) and master (owner --
-- previously had zero visibility into this state, since the existing
-- generic 'service_booked' notification below is operation_admin-only).
--
-- Body is verbatim from the currently-live book_service_ticket
-- (20260804200000_restore_customer_unavailability_booking.sql) -- same
-- signature, only the one new notification insert is added.

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

    -- NEW: distinct, one-time flag reaching both roles that currently work
    -- this queue -- operation_admin (assignment is blocked until a product
    -- is filled in) and master (previously had no visibility at all into
    -- this state; the generic 'service_booked' notification below is
    -- operation_admin-only).
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    select p_org_id, r, 'service_missing_product', 'Service booked without a product',
      format('%s — no product selected, so a technician cannot be auto-assigned until one is added to the ticket.', p_name_of_complaint),
      v_ticket_id
    from unnest(array['operation_admin', 'master']::user_role[]) as r;
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

-- Intentionally NOT re-granted — unchanged signature, create-or-replace
-- preserves the existing grant to `authenticated`.
