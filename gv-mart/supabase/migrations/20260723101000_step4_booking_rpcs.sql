-- STEP 4 (Meeting spec Section B / Build Order Step 4): wire B1/B2/B3 into
-- the two customer-negotiated booking entry points, same scope boundary
-- 20260721091000 already drew ("AMC/warranty visit loops are fixed-cadence
-- auto-scheduled maintenance, not customer-negotiated, out of scope" —
-- unchanged here). Does NOT touch public._auto_assign_ticket_internal
-- (STEP 3 owns it this round) — both functions below only ever CALL that
-- engine (unmodified) once or twice per booking; all new B1-B3 behaviour is
-- new orchestration around it, using the schema/helpers from
-- 20260723100000_step4_booking_model_schema.sql.
--
-- New trailing parameter on both: p_unavailable_windows jsonb default null,
-- a jsonb array of {"start":"HH:MM","end":"HH:MM"} — the raw windows the
-- customer marked as NOT available on their chosen date (can be an EMPTY
-- array: that's "Any time" — the full working-hours window, per B1).
--
-- Backward compatibility: when p_unavailable_windows is null (any caller
-- not yet updated to send it), both functions fall through to the exact
-- pre-existing behaviour verbatim (single insert, single assign attempt,
-- p_available_from/p_available_to used as-is) — zero behaviour change for
-- that case. The new B1/B2/B3 computation only engages when
-- p_appointment_mode = 'datetime', p_scheduled_at is not null (its DATE
-- part is what matters now — the time-of-day component is ignored/
-- overwritten by the derived window), and p_unavailable_windows is
-- non-null. The real callers (BookServicePage.tsx, NewComplaintPage.tsx)
-- are updated to always pass it (possibly '[]') for exactly this reason.
--
-- DROP + CREATE for both, same reasoning as 20260721091000 (adding a
-- parameter changes the signature; CREATE OR REPLACE cannot do that — see
-- that migration's header for the full citation). Both re-granted to
-- authenticated afterward for the same reason (DROP wipes grants).

-- ── create_complaint_ticket ─────────────────────────────────────────────
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean, time, time
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
  returning id, estimated_duration_minutes into v_ticket_id, v_estimated_minutes;

  if p_appointment_mode is not null then
    if p_appointment_mode = 'datetime' and p_scheduled_at is not null and p_unavailable_windows is not null then
      -- B1/B2/B3 path — see file header. p_auto_assign=false just books the
      -- window and stops (no engine call, no next-day bump: there is
      -- nothing to discover "full" without attempting an assignment).
      v_target_date := p_scheduled_at::date;
      v_bumped := false;
      v_attempt := 0;

      insert into public.appointments (org_id, ticket_id, mode, status)
      values (p_org_id, v_ticket_id, p_appointment_mode, 'scheduled')
      returning id into v_appointment_id;

      loop
        v_attempt := v_attempt + 1;
        v_blocked := coalesce(p_unavailable_windows, '[]'::jsonb)
          || public._customer_exemption_blocks(p_org_id, p_customer_id, v_target_date);
        v_window := public._largest_free_window(v_settings.work_start, v_settings.work_end, v_blocked);
        v_window_minutes := coalesce((v_window ->> 'minutes')::integer, 0);
        v_avail_from := (v_window ->> 'available_from')::time;
        v_avail_to := (v_window ->> 'available_to')::time;
        -- B2: narrow guard. is_narrow is purely "small window" (settings
        -- threshold); v_geometrically_ok additionally fails a narrow window
        -- that's physically shorter than the job itself — no point handing
        -- the engine a slot nothing can be completed in.
        v_is_narrow := v_avail_from is not null and v_window_minutes <= v_settings.narrow_window_threshold_minutes;
        v_geometrically_ok := v_avail_from is not null
          and (not v_is_narrow or v_window_minutes >= coalesce(v_estimated_minutes, 0));

        if v_geometrically_ok then
          update public.appointments
          set scheduled_at = v_target_date + v_avail_from,
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = v_is_narrow,
              next_day_priority = v_bumped,
              rescheduled_from_date = case when v_bumped then p_scheduled_at::date else null end
          where id = v_appointment_id;

          exit when not p_auto_assign;

          v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
          exit when coalesce((v_assign_result ->> 'assigned')::boolean, false);
          exit when v_attempt >= 2 or (v_assign_result ->> 'reason_key') is distinct from 'service.assign.noneAvailable';
        elsif v_attempt >= 2 then
          -- B3's next-day bump also failed to find any window at all
          -- (fully blocked both days) — land here and flag ops directly,
          -- since the engine is never called this pass to do it itself.
          update public.appointments
          set scheduled_at = v_target_date + coalesce(v_avail_from, v_settings.work_start),
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = true,
              next_day_priority = true,
              rescheduled_from_date = p_scheduled_at::date
          where id = v_appointment_id;

          if p_auto_assign then
            insert into public.notifications (org_id, role, type, title, body, ref_id)
            values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
              format('Customer-marked unavailable windows leave no bookable slot for ticket %s even after moving to the next day.', v_ticket_id),
              v_ticket_id);
          end if;
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

  -- B3 feedback: let the caller show "moved to the next day" / narrow-window
  -- messaging without a second round trip.
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

-- ── book_service_ticket ─────────────────────────────────────────────────
drop function if exists public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz, time, time
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
  p_appointment_mode appointment_mode,
  p_scheduled_at timestamptz,
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

  if p_appointment_mode is not null then
    if p_appointment_mode = 'datetime' and p_scheduled_at is not null and p_unavailable_windows is not null then
      -- B1/B2/B3 path — see file header + create_complaint_ticket's mirror
      -- of this block for the full walkthrough. Customer self-booking
      -- always auto-assigns (no p_auto_assign flag here, matching the
      -- pre-existing unconditional call below), so the retry/bump loop
      -- always attempts assignment.
      v_target_date := p_scheduled_at::date;
      v_bumped := false;
      v_attempt := 0;

      insert into public.appointments (org_id, ticket_id, mode, status)
      values (p_org_id, v_ticket_id, p_appointment_mode, 'scheduled')
      returning id into v_appointment_id;

      loop
        v_attempt := v_attempt + 1;
        v_blocked := coalesce(p_unavailable_windows, '[]'::jsonb)
          || public._customer_exemption_blocks(p_org_id, v_customer_id, v_target_date);
        v_window := public._largest_free_window(v_settings.work_start, v_settings.work_end, v_blocked);
        v_window_minutes := coalesce((v_window ->> 'minutes')::integer, 0);
        v_avail_from := (v_window ->> 'available_from')::time;
        v_avail_to := (v_window ->> 'available_to')::time;
        v_is_narrow := v_avail_from is not null and v_window_minutes <= v_settings.narrow_window_threshold_minutes;
        v_geometrically_ok := v_avail_from is not null
          and (not v_is_narrow or v_window_minutes >= coalesce(v_estimated_minutes, 0));

        if v_geometrically_ok then
          update public.appointments
          set scheduled_at = v_target_date + v_avail_from,
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = v_is_narrow,
              next_day_priority = v_bumped,
              rescheduled_from_date = case when v_bumped then p_scheduled_at::date else null end
          where id = v_appointment_id;

          v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
          exit when coalesce((v_assign_result ->> 'assigned')::boolean, false);
          exit when v_attempt >= 2 or (v_assign_result ->> 'reason_key') is distinct from 'service.assign.noneAvailable';
        elsif v_attempt >= 2 then
          update public.appointments
          set scheduled_at = v_target_date + coalesce(v_avail_from, v_settings.work_start),
              available_from = v_avail_from,
              available_to = v_avail_to,
              is_narrow_window = true,
              next_day_priority = true,
              rescheduled_from_date = p_scheduled_at::date
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
    else
      -- Legacy path — verbatim from 20260721091000.
      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status, available_from, available_to)
      values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled', p_available_from, p_available_to)
      returning id into v_appointment_id;

      v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
    end if;
  end if;

  -- Design Deltas §36: unknown product -> also logged as a service enquiry
  -- lead (kind='service'). Part 3: reuse a recent still-open lead for this
  -- customer instead of creating a disconnected duplicate — the repeat
  -- enquiry becomes a new activity on the existing lead's timeline.
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

  -- B3 feedback: let the caller show "moved to the next day" / narrow-window
  -- messaging without a second round trip.
  if v_appointment_id is not null then
    select * into v_appointment_snapshot from public.appointments where id = v_appointment_id;
  end if;

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
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz, time, time, jsonb
) to authenticated;
