-- Issue-based spare suggestions, replacing the on-site "Suggested for this
-- product" flow's dependence on product_spares. Today SpareSelectStep.tsx
-- suggests spares purely from the job's product (product_spares), so a
-- "not charging" job and a "physical damage" job on the same battery model
-- show identical suggestions -- the complaint was never part of the query.
--
-- This adds:
-- 1. service_tickets.complaint_type_id -- both book_service_ticket (customer
--    app) and create_complaint_ticket (admin "New Complaint") already run an
--    Autocomplete sourced from complaint_types whose onSelect(ct) discards
--    ct.id and keeps only the label; threading the id through lets the
--    ticket carry which complaint_types row was actually picked.
-- 2. complaint_type_spares -- a many-to-many complaint_type<->spare mapping,
--    identical shape/RLS/audit to product_spares
--    (20260730170000_product_spare_mapping_and_active_flags.sql), admin-
--    managed from Masters > Complaint Types (category defaults) and the
--    per-product complaints panel (product-specific overrides) -- both
--    write to the same complaint_types table, so one mapping table serves
--    both.
--
-- book_service_ticket/create_complaint_ticket gain p_complaint_type_id as a
-- new trailing default param, append-only -- do not touch any existing
-- param's position or type (20260804180000_fix_create_complaint_ticket_
-- overload.sql documents what happens if you do: Postgres silently creates
-- a second overload instead of replacing the function).

alter table public.service_tickets
  add column if not exists complaint_type_id uuid references public.complaint_types (id);

create table if not exists public.complaint_type_spares (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  complaint_type_id uuid not null references public.complaint_types (id) on delete cascade,
  spare_id uuid not null references public.spares (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (complaint_type_id, spare_id)
);

create index if not exists complaint_type_spares_org_id_idx on public.complaint_type_spares (org_id);
create index if not exists complaint_type_spares_complaint_type_id_idx on public.complaint_type_spares (complaint_type_id);
create index if not exists complaint_type_spares_spare_id_idx on public.complaint_type_spares (spare_id);

alter table public.complaint_type_spares enable row level security;

create policy complaint_type_spares_select_org on public.complaint_type_spares for select using (org_id = public.current_org_id());
create policy complaint_type_spares_write_master on public.complaint_type_spares for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_complaint_type_spares after insert or update or delete on public.complaint_type_spares for each row execute function public.audit_master_change();

-- book_service_ticket: body verbatim from the currently-live version
-- (20260806120000_notify_master_on_missing_product_booking.sql), only
-- p_complaint_type_id added (new trailing param) and threaded into the
-- service_tickets insert.
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
  p_unavailable_windows jsonb default '[]'::jsonb,
  p_complaint_type_id uuid default null
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
    name_of_complaint, nature_of_complaint, complaint_type_id, type, priority, status, channel, sla_due_at
  ) values (
    p_org_id, v_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), p_complaint_type_id, v_type, p_priority, 'open', 'customer_app',
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

-- create_complaint_ticket: body verbatim from the currently-live version
-- (20260804180000_fix_create_complaint_ticket_overload.sql), only
-- p_complaint_type_id added (new trailing param, 17th) and threaded into
-- the service_tickets insert.
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
  p_complaint_type_id uuid default null
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
    name_of_complaint, nature_of_complaint, complaint_type_id, type, priority, status, channel, sla_due_at, lead_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id, nullif(btrim(coalesce(p_unlisted_product_name, '')), ''),
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), p_complaint_type_id, v_type, p_priority, 'open', p_channel,
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

-- Intentionally NOT re-granted on either function — unchanged signature
-- position/types for all prior params (only a new trailing default param
-- added), so CREATE OR REPLACE preserves the existing grant to
-- `authenticated` rather than creating a second overload.

-- Seed complaint_type_spares with every plausible issue->spare pairing
-- given the current spares catalog (queried live: 44 complaint_types across
-- ro/ac/inverter/battery, 20 spares). Matched by (category, label) ->
-- spare name rather than hardcoded ids, same portable idiom as
-- 20260803140000_seed_complaint_types.sql. Idempotent via NOT EXISTS.
--
-- Inverter and battery only have one spare each in the catalog today
-- (Inverter Fuse / Battery Terminal Connector), so several issues in those
-- two categories are deliberately left unmapped below (e.g. "Battery
-- leaking", "Display not working") rather than force-fitting an irrelevant
-- spare — those categories need more SKUs added to Masters > Spares before
-- their suggestions can be as useful as RO/AC's.
insert into public.complaint_type_spares (org_id, complaint_type_id, spare_id)
select ct.org_id, ct.id, s.id
from (
  values
    ('ro'::brand_category, 'Making unusual noise', 'Booster Pump'),
    ('ro', 'Making unusual noise', 'Solenoid Valve'),
    ('ro', 'Water leakage', 'Solenoid Valve'),
    ('ro', 'Water leakage', 'Storage Tank 8L'),
    ('ro', 'Water leakage', 'Non-Return Valve (NRV)'),
    ('ro', 'Continuous dripping even when tank is full', 'Float Valve'),
    ('ro', 'Continuous dripping even when tank is full', 'Solenoid Valve'),
    ('ro', 'Auto shut-off not working', 'Float Valve'),
    ('ro', 'Auto shut-off not working', 'Solenoid Valve'),
    ('ro', 'Low water pressure', 'Sediment Filter (RO)'),
    ('ro', 'Low water pressure', 'Pre-Carbon Filter (RO)'),
    ('ro', 'Low water pressure', 'Booster Pump'),
    ('ro', 'Low water pressure', 'RO Membrane 75 GPD'),
    ('ro', 'Water looks cloudy or milky', 'Sediment Filter (RO)'),
    ('ro', 'Water looks cloudy or milky', 'RO Membrane 75 GPD'),
    ('ro', 'Water looks cloudy or milky', 'Post-Carbon Filter (RO)'),
    ('ro', 'Purifier not powering on', 'SMPS Adapter 24V'),
    ('ro', 'Water tastes bad / bad odor', 'Post-Carbon Filter (RO)'),
    ('ro', 'Water tastes bad / bad odor', 'Pre-Carbon Filter (RO)'),
    ('ro', 'Water tastes bad / bad odor', 'UF Membrane'),
    ('ro', 'No water output', 'Booster Pump'),
    ('ro', 'No water output', 'Solenoid Valve'),
    ('ro', 'No water output', 'SMPS Adapter 24V'),
    ('ro', 'No water output', 'Non-Return Valve (NRV)'),
    ('ro', 'Tank not filling', 'Float Valve'),
    ('ro', 'Tank not filling', 'Solenoid Valve'),
    ('ro', 'Tank not filling', 'Non-Return Valve (NRV)'),
    ('ro', 'Filter change indicator not working', 'SMPS Adapter 24V'),
    ('ro', 'Filter change indicator not working', 'TDS Controller'),
    ('ro', 'TDS / purity not up to standard', 'RO Membrane 75 GPD'),
    ('ro', 'TDS / purity not up to standard', 'TDS Controller'),
    ('ro', 'TDS / purity not up to standard', 'Pre-Carbon Filter (RO)'),

    ('ac', 'Outdoor unit not running', 'AC Compressor Capacitor'),
    ('ac', 'Outdoor unit not running', 'AC PCB Board'),
    ('ac', 'Unusual noise from unit', 'AC Compressor Capacitor'),
    ('ac', 'Unusual noise from unit', 'AC Cooling Coil'),
    ('ac', 'Bad smell / odor', 'AC Cooling Coil'),
    ('ac', 'Remote not working', 'AC Remote Control'),
    ('ac', 'Water leakage from indoor unit', 'AC Cooling Coil'),
    ('ac', 'High power consumption', 'AC Compressor Capacitor'),
    ('ac', 'High power consumption', 'Gas Refill Can R32 (1kg)'),
    ('ac', 'AC not turning on', 'AC PCB Board'),
    ('ac', 'AC not turning on', 'AC Compressor Capacitor'),
    ('ac', 'Ice formation on coil', 'Gas Refill Can R32 (1kg)'),
    ('ac', 'Ice formation on coil', 'AC Cooling Coil'),
    ('ac', 'Weak airflow', 'AC Cooling Coil'),
    ('ac', 'Not cooling', 'Gas Refill Can R32 (1kg)'),
    ('ac', 'Not cooling', 'AC Compressor Capacitor'),
    ('ac', 'Not cooling', 'AC Cooling Coil'),
    ('ac', 'AC turns off automatically', 'AC PCB Board'),
    ('ac', 'AC turns off automatically', 'AC Compressor Capacitor'),
    ('ac', 'Display / error code shown', 'AC PCB Board'),

    ('inverter', 'Burning smell', 'Inverter Fuse'),
    ('inverter', 'Low output voltage', 'Inverter Fuse'),
    ('inverter', 'Not switching to backup automatically', 'Inverter Fuse'),
    ('inverter', 'Overload trip', 'Inverter Fuse'),
    ('inverter', 'Inverter not turning on', 'Inverter Fuse'),
    ('inverter', 'Continuous beeping / alarm sound', 'Inverter Fuse'),
    ('inverter', 'Not charging', 'Inverter Fuse'),
    ('inverter', 'No power backup during outage', 'Inverter Fuse'),

    ('battery', 'Terminal corrosion', 'Battery Terminal Connector'),
    ('battery', 'Draining too quickly', 'Battery Terminal Connector'),
    ('battery', 'Not holding charge', 'Battery Terminal Connector'),
    ('battery', 'Not charging', 'Battery Terminal Connector')
) as v(category, label, spare_name)
join public.complaint_types ct on ct.product_category = v.category and ct.label = v.label and ct.product_id is null
join public.spares s on s.org_id = ct.org_id and s.name = v.spare_name
where not exists (
  select 1 from public.complaint_type_spares cts
  where cts.complaint_type_id = ct.id and cts.spare_id = s.id
);
