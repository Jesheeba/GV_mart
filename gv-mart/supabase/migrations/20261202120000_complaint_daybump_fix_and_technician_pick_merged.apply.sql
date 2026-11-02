-- APPLY script for 20261202120000_complaint_daybump_fix_and_technician_pick_merged.sql
-- Refuses (RAISE EXCEPTION, no DDL touched) if this version is already
-- registered in supabase_migrations.schema_migrations. Otherwise applies
-- the migration's DDL (verbatim) and registers the version. Multiple
-- statements in one query string via run_rehearsal.mjs run as one
-- implicit transaction -- if the final INSERT fails, the DDL above it
-- rolls back too.

do $guard$
begin
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261202120000') then
    raise exception 'already registered: migration 20261202120000 has already been applied -- refusing to re-apply';
  end if;
end $guard$;

-- ── 1. _create_complaint_ticket_internal (18-param overload only) ──────────
drop function if exists public._create_complaint_ticket_internal(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb
);

create function public._create_complaint_ticket_internal(
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
  p_unavailable_windows jsonb default null,
  p_technician_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

          -- Urgent item #1: an explicit pick always takes priority over
          -- auto-assign, and reuses assign_ticket_technician's own
          -- busy/conflict checks rather than duplicating them.
          if p_technician_id is not null then
            v_assign_result := public.assign_ticket_technician(v_appointment_id, p_technician_id);
          elsif p_auto_assign then
            v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
          end if;

          -- Urgent item #4 fix: once the day is geometrically bookable,
          -- commit to it and stop -- a failed/skipped assignment attempt no
          -- longer feeds back into the day-bump loop below. Either
          -- assign_ticket_technician or _auto_assign_ticket_internal already
          -- raises its own notification when nobody ends up assigned, so ops
          -- still gets paged; the ticket just keeps the date the master
          -- actually chose instead of silently moving it.
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

      if p_technician_id is not null then
        v_assign_result := public.assign_ticket_technician(v_appointment_id, p_technician_id);
      elsif p_auto_assign then
        v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
      end if;
    end if;
  elsif p_appointment_mode = 'always' then
    insert into public.appointments (org_id, ticket_id, mode, status)
    values (p_org_id, v_ticket_id, 'always', 'scheduled')
    returning id into v_appointment_id;

    if p_technician_id is not null then
      v_assign_result := public.assign_ticket_technician(v_appointment_id, p_technician_id);
    elsif p_auto_assign then
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
$function$;

revoke all on function public._create_complaint_ticket_internal(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid
) from public, anon, authenticated;
grant execute on function public._create_complaint_ticket_internal(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid
) to service_role;

-- ── 2. create_complaint_ticket (public entry point) ─────────────────────────
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb
);

create function public.create_complaint_ticket(
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
  p_unavailable_windows jsonb default null,
  p_technician_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
    p_unavailable_windows, p_technician_id
  );
end;
$function$;

revoke all on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid
) from public, anon;
grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel,
  appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid
) to authenticated, service_role;

-- ── register ─────────────────────────────────────────────────────────────
insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261202120000', 'complaint_daybump_fix_and_technician_pick_merged', array[]::text[]);

select
  'applied' as status,
  now() as applied_at,
  (select pg_get_function_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='create_complaint_ticket') as create_complaint_ticket_args,
  (select pg_get_function_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_create_complaint_ticket_internal' and pg_get_function_arguments(p.oid) like '%p_technician_id%') as internal_args;
