-- Fixes a real, live, app-wide timezone bug found 2026-07-31 while
-- verifying Task 5 (see GV Mart memory gv_mart_timezone_display_bug for the
-- full writeup). Every function that builds `appointments.scheduled_at`
-- (a `timestamptz`) from a local-intended date + time-of-day did so with a
-- naive `date + time` (or `date::timestamptz + time`) expression. Postgres
-- casts that using the SESSION's default timezone, which is UTC on this
-- database — so "2pm" got stored as `14:00:00+00:00` (literally 2pm UTC)
-- instead of the correct `08:30:00+00:00` (2pm IST). Every display call
-- site in the frontend does a REAL timezone conversion
-- (`Date.toLocaleString()` with no explicit `timeZone`), so on any client
-- actually running in India Standard Time the shown time is off by exactly
-- UTC+5:30.
--
-- Fix: wrap every such construction in `at time zone 'Asia/Kolkata'`, which
-- correctly interprets the naive date+time digits as IST and converts to
-- the true UTC instant for storage. Frontend display code needs NO changes
-- — it already does real timezone conversion; it was only ever wrong
-- because the stored instant was wrong.
--
-- Every function below is redefined here VERBATIM from its currently-live
-- body (confirmed via a full grep-and-trace across every migration that
-- ever touched each name, resolving drop/recreate and overload history —
-- see the memory note above for the full audit trail) with ONLY the
-- `scheduled_at` construction changed. Nothing else in any function body
-- is altered.

-- ── create_complaint_ticket (live in 20260723101000_step4_booking_rpcs.sql) ──
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
          set scheduled_at = (v_target_date + v_avail_from) at time zone 'Asia/Kolkata',
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
          set scheduled_at = (v_target_date + coalesce(v_avail_from, v_settings.work_start)) at time zone 'Asia/Kolkata',
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

-- ── book_service_ticket (live in 20260723101000_step4_booking_rpcs.sql) ──
drop function if exists public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz, time, time, jsonb
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
          set scheduled_at = (v_target_date + v_avail_from) at time zone 'Asia/Kolkata',
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
          set scheduled_at = (v_target_date + coalesce(v_avail_from, v_settings.work_start)) at time zone 'Asia/Kolkata',
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

-- ── sell_amc_plan (live in 20260716130000_amc_price_per_year_and_covered_spares.sql) ──
create or replace function public.sell_amc_plan(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_start_date date default current_date,
  p_years integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan amc_plans;
  v_years integer;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
begin
  if not (public.is_ops_staff() or public.is_sales_staff()) then
    raise exception 'sell_amc_plan: only master, operation_admin, or sales_admin may sell an AMC plan';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan: org mismatch';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'sell_amc_plan: years must be greater than zero';
  end if;

  v_expiry := p_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_visit_date := p_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := p_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id
    ) values (
      p_org_id, p_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'call', v_contract_id
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', (v_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled')
    returning id into v_appointment_id;

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer) to authenticated;

-- ── renew_amc_plan (live in 20260730110000_address_everywhere.sql) ──
create or replace function public.renew_amc_plan(
  p_org_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_reference text,
  p_years integer default null,
  p_referred_by_technician_name text default null,
  p_address_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_plan amc_plans;
  v_years integer;
  v_existing amc_contracts;
  v_settings settings;
  v_start_date date;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_contract_id uuid;
  v_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'renew_amc_plan: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'renew_amc_plan: org mismatch';
  end if;
  if p_payment_reference is null or btrim(p_payment_reference) = '' then
    raise exception 'renew_amc_plan: a payment reference is required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'renew_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'renew_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > current_date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    select count(*), min(t.id) into v_tech_match_count, v_tech_id
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count <> 1 then
      v_tech_id := null;
    end if;
  end if;

  if v_tech_id is not null then
    select name into v_customer_name from public.customers where id = v_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', v_tech_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', format('AMC self-service purchase, referred by %s', p_referred_by_technician_name));
  end if;

  v_start_date := greatest(current_date, coalesce(v_existing.expiry_date, current_date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'customer_app', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', (v_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) — payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.renew_amc_plan(uuid, uuid, uuid, text, integer, text, uuid) to authenticated;

-- ── register_product_via_qr (live in 20260716132000_warranty_scheduled_visits.sql) ──
create or replace function public.register_product_via_qr(
  p_org_id uuid,
  p_product_id uuid,
  p_serial_no text,
  p_purchase_date date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_product products;
  v_warranty_id uuid;
  v_warranty warranties;
  v_address_id uuid;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'register_product_via_qr: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'register_product_via_qr: org mismatch';
  end if;

  select * into v_product from public.products where id = p_product_id and org_id = p_org_id;
  if v_product.id is null then
    raise exception 'register_product_via_qr: product % not found', p_product_id;
  end if;

  if p_serial_no is not null and btrim(p_serial_no) <> '' and exists (
    select 1 from public.warranties where org_id = p_org_id and serial_no = p_serial_no
  ) then
    raise exception 'register_product_via_qr: serial number % is already registered', p_serial_no;
  end if;

  insert into public.warranties (org_id, customer_id, product_id, serial_no, start_date, expiry_date)
  values (
    p_org_id, v_customer_id, p_product_id, nullif(btrim(p_serial_no), ''),
    coalesce(p_purchase_date, current_date),
    coalesce(p_purchase_date, current_date) + make_interval(months => v_product.warranty_months)
  )
  returning id into v_warranty_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'product_registered', 'Product registered via QR', v_product.name, v_warranty_id);

  select * into v_warranty from public.warranties where id = v_warranty_id;
  select a.id into v_address_id from public.addresses a
  where a.customer_id = v_customer_id and a.is_primary = true limit 1;

  v_total_visits := floor(
    (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
      + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
  )::integer;

  v_visit_date := v_warranty.start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
    exit when v_visit_date > v_warranty.expiry_date;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('Warranty scheduled service %s of %s', i, v_total_visits), 'Warranty scheduled service',
      'warranty', 'normal', 'open', 'customer_app'
    )
    returning id into v_ticket_id;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', (v_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);

    if i = 1 then
      update public.warranties set next_service_date = v_visit_date where id = v_warranty_id;
    end if;
  end loop;

  return v_warranty_id;
end;
$$;

grant execute on function public.register_product_via_qr(uuid, uuid, text, date) to authenticated;

-- ── sell_amc_plan_onsite (live, only definition, in 20260724100000_technician_onsite_amc_sale.sql) ──
create or replace function public.sell_amc_plan_onsite(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_method payment_method,
  p_txn_id text default null,
  p_payment_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_customer_name text;
  v_lead_id uuid;
  v_settings settings;
  v_plan amc_plans;
  v_effective_price numeric(12, 2);
  v_discount numeric(12, 2) := 0;
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_invoice invoices;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'sell_amc_plan_onsite: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan_onsite: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'sell_amc_plan_onsite: customer % not found in org %', p_customer_id, p_org_id;
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan_onsite: AMC plans are only sold on RO products';
  end if;
  if p_payment_method = 'transfer' and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'sell_amc_plan_onsite: bank transfer requires a transaction ID and description';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan_onsite: plan % not found', p_plan_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'sell_amc_plan_onsite: no settings row for org %', p_org_id;
  end if;

  select name into v_customer_name from public.customers where id = p_customer_id;
  insert into public.leads (org_id, customer_id, name, source, status, owner_id)
  values (p_org_id, p_customer_id, coalesce(v_customer_name, 'On-site AMC customer'), 'field', 'won', v_tech_id)
  returning id into v_lead_id;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'converted', format('On-site AMC sale (%s) by technician', v_plan.name));

  v_effective_price := coalesce(v_plan.price_per_year * v_plan.years, v_plan.price);
  v_gst := round(v_effective_price * v_settings.gst_rate / 100, 2);
  v_total := v_effective_price + v_gst;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, sold_by
  ) values (
    p_org_id, p_customer_id, 'amc', v_effective_price, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''), 'paid', auth.uid()
  ) returning * into v_invoice;

  v_expiry := current_date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
  values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, current_date,
    v_expiry, 'active', current_date + make_interval(months => v_interval_months), v_invoice.id
  )
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_invoice.id, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_visit_date := current_date;
  for i in 1..v_total_visits loop
    v_visit_date := current_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, p_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'field', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', (v_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold on-site',
    format('%s AMC contract sold on-site by a technician, %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)),
    v_contract_id
  );

  return jsonb_build_object(
    'invoice_id', v_invoice.id,
    'contract_id', v_contract_id,
    'ticket_ids', to_jsonb(v_ticket_ids),
    'expiry_date', v_expiry,
    'lead_id', v_lead_id
  );
end;
$$;

grant execute on function public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text) to authenticated;

-- ── create_sale (live in 20260723131000_finder_credit_functions.sql) ──
create or replace function public.create_sale(
  p_org_id uuid,
  p_customer_id uuid,
  p_cart jsonb,
  p_quotation_id uuid default null,
  p_redeem_points integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings settings;
  v_discount_percent numeric(5, 2);
  v_payment_method payment_method;
  v_spare_invoice invoices;
  v_product_invoice invoices;
  v_amc_invoice invoices;
  v_primary_invoice_id uuid;
  v_combined_subtotal numeric(12, 2);
  v_gift_id uuid;
  v_gift gifts;
  v_approval_id uuid;
  v_item record;
  v_warranty_id uuid;
  v_ticket_id uuid;
  v_tech_id uuid;
  v_amc_product_id uuid;
  v_amc_plan_id uuid;
  v_amc_plan amc_plans;
  v_amc_discount numeric(12, 2);
  v_amc_gst numeric(12, 2);
  v_amc_total numeric(12, 2);
  v_amc_contract_id uuid;
  v_amc_expiry date;
  v_amc_interval_months integer;
  v_amc_total_visits integer;
  v_amc_visit_date date;
  v_amc_ticket_id uuid;
  v_amc_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_warranty_ids uuid[] := '{}';
  v_has_amc boolean;
  v_redeem_points integer := 0;
  v_redeem_balance integer;
  v_redeem_amount numeric(12, 2) := 0;
  v_primary_invoice_total numeric(12, 2);
  v_warranty warranties;
  v_warranty_address_id uuid;
  v_warranty_total_visits integer;
  v_warranty_visit_date date;
  v_warranty_ticket_id uuid;
  v_amc_effective_price numeric(12, 2);
  v_lead_id uuid; -- FINDER CREDIT: source lead behind p_quotation_id, if any
begin
  if not public.is_sales_staff() then
    raise exception 'create_sale: only master or sales_admin may create a sale';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_sale: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_sale: customer % not found in org %', p_customer_id, p_org_id;
  end if;

  if p_quotation_id is not null then
    select lead_id into v_lead_id from public.quotations where id = p_quotation_id and org_id = p_org_id;
  end if;

  v_has_amc := p_cart -> 'amc' is not null and p_cart -> 'amc' <> 'null'::jsonb;
  if coalesce(jsonb_array_length(p_cart -> 'spare_items'), 0) = 0
     and coalesce(jsonb_array_length(p_cart -> 'product_items'), 0) = 0
     and not v_has_amc then
    raise exception 'create_sale: cart is empty';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_sale: no settings row for org %', p_org_id;
  end if;

  v_discount_percent := coalesce((p_cart ->> 'discount_percent')::numeric, 0);
  if v_discount_percent < 0 then
    raise exception 'create_sale: discount cannot be negative';
  end if;
  if v_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_sale: discount % exceeds the admin limit of %', v_discount_percent, v_settings.discount_admin_max;
  end if;

  v_payment_method := nullif(p_cart ->> 'payment_method', '')::payment_method;
  if v_payment_method is null then
    raise exception 'create_sale: payment_method is required';
  end if;
  if v_payment_method = 'transfer'
     and (nullif(p_cart ->> 'txn_id', '') is null or nullif(p_cart ->> 'payment_description', '') is null) then
    raise exception 'create_sale: bank transfer requires a transaction ID and description';
  end if;

  v_redeem_points := coalesce(p_redeem_points, 0);
  if v_redeem_points < 0 then
    raise exception 'create_sale: redeem points cannot be negative';
  end if;
  if v_redeem_points > 0 then
    select coalesce(sum(points), 0) into v_redeem_balance
    from public.referral_points
    where customer_id = p_customer_id and org_id = p_org_id;

    if v_redeem_points > v_redeem_balance then
      raise exception 'create_sale: cannot redeem % referral points — customer % has a balance of only %', v_redeem_points, p_customer_id, v_redeem_balance;
    end if;

    v_redeem_amount := round(v_redeem_points * v_settings.referral_point_value, 2);
  end if;

  v_spare_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'spare', p_cart -> 'spare_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  v_product_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'product', p_cart -> 'product_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  if v_product_invoice.id is not null then
    for v_item in
      select * from jsonb_to_recordset(p_cart -> 'product_items')
        as x(item_id uuid, qty integer, warranty boolean, warranty_months integer, installation boolean)
    loop
      if coalesce(v_item.warranty, false) then
        insert into public.warranties (org_id, customer_id, product_id, start_date, expiry_date, invoice_id)
        select p_org_id, p_customer_id, v_item.item_id, current_date,
               current_date + (coalesce(v_item.warranty_months, p.warranty_months) || ' months')::interval,
               v_product_invoice.id
        from public.products p where p.id = v_item.item_id
        returning id into v_warranty_id;
        v_warranty_ids := array_append(v_warranty_ids, v_warranty_id);

        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (
          p_org_id, 'operation_admin', 'warranty_registered', 'Warranty registered',
          format('A warranty was registered from invoice %s.', v_product_invoice.id), v_warranty_id
        );

        select * into v_warranty from public.warranties where id = v_warranty_id;
        select a.id into v_warranty_address_id from public.addresses a
        where a.customer_id = p_customer_id and a.is_primary = true limit 1;

        v_warranty_total_visits := floor(
          (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
            + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
        )::integer;

        v_warranty_visit_date := v_warranty.start_date;
        for i in 1..v_warranty_total_visits loop
          v_warranty_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
          exit when v_warranty_visit_date > v_warranty.expiry_date;

          insert into public.service_tickets (
            org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
            type, priority, status, channel, lead_id
          ) values (
            p_org_id, p_customer_id, v_warranty_address_id, v_item.item_id,
            format('Warranty scheduled service %s of %s', i, v_warranty_total_visits), 'Warranty scheduled service',
            'warranty', 'normal', 'open', 'walk_in', v_lead_id -- FINDER CREDIT
          )
          returning id into v_warranty_ticket_id;
          v_ticket_ids := array_append(v_ticket_ids, v_warranty_ticket_id);

          insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
          values (p_org_id, v_warranty_ticket_id, 'datetime', (v_warranty_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

          perform public._auto_assign_ticket_internal(v_warranty_ticket_id, p_org_id, p_skip_rating_logic => true);

          if i = 1 then
            update public.warranties set next_service_date = v_warranty_visit_date where id = v_warranty_id;
          end if;
        end loop;
      end if;

      if coalesce(v_item.installation, false) then
        insert into public.service_tickets (
          org_id, customer_id, product_id, brand_id, model_id,
          name_of_complaint, nature_of_complaint, type, priority, status, channel, invoice_id, lead_id
        )
        select p_org_id, p_customer_id, v_item.item_id, p.brand_id, p.model_id,
               'Installation', 'New product installation', 'installation', 'normal', 'open', 'walk_in', v_product_invoice.id, v_lead_id -- FINDER CREDIT
        from public.products p where p.id = v_item.item_id
        returning id into v_ticket_id;
        v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

        select t.id into v_tech_id
        from public.technicians t
        where t.org_id = p_org_id and t.is_on_duty = true
          and not exists (
            select 1 from public.appointments a
            where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
          )
        order by t.created_at
        for update skip locked
        limit 1;

        if v_tech_id is not null then
          insert into public.appointments (org_id, ticket_id, technician_id, mode, status)
          values (p_org_id, v_ticket_id, v_tech_id, 'always', 'scheduled');
          update public.service_tickets set status = 'assigned' where id = v_ticket_id;
        else
          insert into public.notifications (org_id, role, type, title, body, ref_id)
          values (
            p_org_id, 'operation_admin', 'installation_unassigned', 'Installation needs manual assignment',
            'No on-duty technician is free right now — assign this installation manually.', v_ticket_id
          );
        end if;
      end if;
    end loop;
  end if;

  if v_has_amc then
    v_amc_product_id := (p_cart -> 'amc' ->> 'product_id')::uuid;
    v_amc_plan_id := (p_cart -> 'amc' ->> 'plan_id')::uuid;

    if not exists (select 1 from public.products where id = v_amc_product_id and org_id = p_org_id and category = 'ro') then
      raise exception 'create_sale: AMC add-on is only available on RO products';
    end if;

    select * into v_amc_plan from public.amc_plans where id = v_amc_plan_id and org_id = p_org_id;
    if v_amc_plan is null then
      raise exception 'create_sale: AMC plan % not found', v_amc_plan_id;
    end if;

    v_amc_effective_price := coalesce(v_amc_plan.price_per_year * v_amc_plan.years, v_amc_plan.price);

    v_amc_discount := round(v_amc_effective_price * v_discount_percent / 100, 2);
    v_amc_gst := round((v_amc_effective_price - v_amc_discount) * v_settings.gst_rate / 100, 2);
    v_amc_total := v_amc_effective_price - v_amc_discount + v_amc_gst;

    insert into public.invoices (
      org_id, customer_id, type, subtotal, discount, gst, total,
      payment_method, txn_id, payment_description, payment_status, sold_by
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_effective_price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid', auth.uid()
    ) returning * into v_amc_invoice;

    v_amc_expiry := current_date + (v_amc_plan.years || ' years')::interval;
    v_amc_interval_months := greatest(1, 12 / v_amc_plan.visits_per_year);
    v_amc_total_visits := v_amc_plan.years * v_amc_plan.visits_per_year;

    insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
    values (
      p_org_id, p_customer_id, v_amc_product_id, v_amc_plan_id, current_date,
      v_amc_expiry, 'active',
      current_date + make_interval(months => v_amc_interval_months),
      v_amc_invoice.id
    )
    returning id into v_amc_contract_id;

    if v_amc_plan.gift_id is not null then
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_amc_invoice.id, v_amc_plan.gift_id);
    end if;

    select a.id into v_amc_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

    v_amc_visit_date := current_date;
    for i in 1..v_amc_total_visits loop
      v_amc_visit_date := current_date + make_interval(months => v_amc_interval_months * i);
      exit when v_amc_visit_date > v_amc_expiry;

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, contract_id, lead_id
      ) values (
        p_org_id, p_customer_id, v_amc_address_id, v_amc_product_id,
        format('AMC scheduled service %s of %s', i, v_amc_total_visits), v_amc_plan.name,
        'amc', 'normal', 'open', 'walk_in', v_amc_contract_id, v_lead_id -- FINDER CREDIT
      )
      returning id into v_amc_ticket_id;
      v_ticket_ids := array_append(v_ticket_ids, v_amc_ticket_id);

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
      values (p_org_id, v_amc_ticket_id, 'datetime', (v_amc_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

      perform public._auto_assign_ticket_internal(v_amc_ticket_id, p_org_id, p_skip_rating_logic => true);
    end loop;
  end if;

  v_primary_invoice_id := coalesce(v_product_invoice.id, v_spare_invoice.id, v_amc_invoice.id);
  v_combined_subtotal := coalesce(v_product_invoice.subtotal, 0) + coalesce(v_spare_invoice.subtotal, 0) + coalesce(v_amc_invoice.subtotal, 0);

  v_gift_id := nullif(p_cart ->> 'gift_id', '')::uuid;
  if v_gift_id is not null and v_primary_invoice_id is not null then
    select * into v_gift from public.gifts where id = v_gift_id and org_id = p_org_id;
    if v_gift is not null and v_combined_subtotal >= v_gift.threshold_amount then
      update public.invoices set gift_id = v_gift_id where id = v_primary_invoice_id;
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_primary_invoice_id, v_gift_id);
    end if;
  end if;

  if v_redeem_points > 0 then
    if v_primary_invoice_id is null then
      raise exception 'create_sale: cannot redeem referral points — the cart produced no invoice to apply them to';
    end if;

    select total into v_primary_invoice_total from public.invoices where id = v_primary_invoice_id;
    v_redeem_amount := least(v_redeem_amount, v_primary_invoice_total);

    update public.invoices set total = total - v_redeem_amount where id = v_primary_invoice_id;

    insert into public.referral_points (org_id, customer_id, points, reason, ref_id)
    values (p_org_id, p_customer_id, -v_redeem_points, 'redeemed_on_sale', v_primary_invoice_id);
  end if;

  if v_discount_percent > v_settings.discount_tech_max and v_primary_invoice_id is not null then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_primary_invoice_id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if p_quotation_id is not null then
    update public.quotations set status = 'converted' where id = p_quotation_id and org_id = p_org_id;

    if v_lead_id is not null then
      update public.leads set status = 'won', updated_at = now() where id = v_lead_id and org_id = p_org_id;
    end if;
  end if;

  return jsonb_build_object(
    'spare_invoice_id', v_spare_invoice.id,
    'product_invoice_id', v_product_invoice.id,
    'amc_invoice_id', v_amc_invoice.id,
    'warranty_ids', to_jsonb(v_warranty_ids),
    'ticket_ids', to_jsonb(v_ticket_ids),
    'approval_id', v_approval_id,
    'redeemed_points', v_redeem_points,
    'redeemed_amount', v_redeem_amount
  );
end;
$$;

grant execute on function public.create_sale(uuid, uuid, jsonb, uuid, integer) to authenticated;

-- ── log_confirmed_availability (Task 5, this session's own new RPC — fixed
-- before it ever shipped a wrong value beyond the throwaway test rows
-- already cleaned up during verification) ──
create or replace function public.log_confirmed_availability(
  p_appointment_id uuid,
  p_reason text,
  p_confirmed_date date,
  p_confirmed_from time,
  p_confirmed_to time,
  p_note text default null
)
returns public.appointment_availability_calls
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_prev_date date;
  v_row public.appointment_availability_calls;
begin
  if not public.is_ops_staff() then
    raise exception 'log_confirmed_availability: only ops staff may log a confirmed-availability call';
  end if;
  if p_reason not in ('customer_followup', 'technician_unavailable') then
    raise exception 'log_confirmed_availability: invalid reason %', p_reason;
  end if;
  if p_confirmed_from >= p_confirmed_to then
    raise exception 'log_confirmed_availability: confirmed_from must be before confirmed_to';
  end if;

  select org_id, scheduled_at::date into v_org_id, v_prev_date
  from public.appointments where id = p_appointment_id;
  if v_org_id is null then
    raise exception 'log_confirmed_availability: appointment % not found', p_appointment_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'log_confirmed_availability: org mismatch';
  end if;

  insert into public.appointment_availability_calls
    (org_id, appointment_id, logged_by, reason, confirmed_date, confirmed_from, confirmed_to, note)
  values
    (v_org_id, p_appointment_id, auth.uid(), p_reason, p_confirmed_date, p_confirmed_from, p_confirmed_to,
     nullif(btrim(coalesce(p_note, '')), ''))
  returning * into v_row;

  update public.appointments
  set scheduled_at = (p_confirmed_date + p_confirmed_from) at time zone 'Asia/Kolkata',
      available_from = p_confirmed_from,
      available_to = p_confirmed_to,
      rescheduled_from_date = case when v_prev_date is distinct from p_confirmed_date then v_prev_date else rescheduled_from_date end
  where id = p_appointment_id;

  return v_row;
end;
$$;

grant execute on function public.log_confirmed_availability(uuid, text, date, time, time, text) to authenticated;

-- ── Historical data correction ──────────────────────────────────────────
-- Every existing 'datetime'-mode appointment written by one of the 7
-- functions above (before this fix) is stored 5 hours 30 minutes too late.
-- Narrowly targeted so a genuinely-correct row (the "legacy path" in
-- create_complaint_ticket/book_service_ticket, which takes an already-
-- correct real UTC instant straight from the frontend) is never touched:
--   - AMC/warranty auto-scheduled visits always write exactly '09:00' local
--     and never set available_from — identified by available_from is null
--     and the UTC time-of-day component still showing 09:00.
--   - Booking-flow (B1/B3) rows always write scheduled_at's time-of-day
--     equal to available_from by construction — identified by that exact
--     equality, which a correctly-converted legacy-path row (real UTC
--     instant vs. a separately-entered local available_from) would not
--     coincidentally match.
update public.appointments
set scheduled_at = scheduled_at - interval '5 hours 30 minutes'
where mode = 'datetime'
  and scheduled_at is not null
  and (
    (available_from is null and scheduled_at::time = time '09:00:00')
    or (available_from is not null and scheduled_at::time = available_from)
  );
