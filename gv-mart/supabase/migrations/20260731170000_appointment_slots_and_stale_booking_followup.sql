-- Customer Dashboard Booking Audit (2026-07-31), Tasks 2/3/4.
--
-- Root cause of Task 4 ("next day priority" shown while technicians are
-- free): book_service_ticket computed bookability from the CUSTOMER'S OWN
-- tapped-unavailable-minutes geometry against settings.work_start/work_end
-- — it never consulted real technician/attendance data before deciding to
-- bump to the next day. Owner-confirmed 2026-07-31: technician availability
-- can't be reliably predicted in advance anyway (a job may overrun), so the
-- fix is NOT "predict better" — it's "stop predicting": accept the
-- customer's requested date+slot unconditionally, let the real assignment
-- engine try once, and only escalate (admins notified + customer told) if
-- the day genuinely ends with no technician ever assigned.
--
-- Tasks 2/3 (admin-configured Morning/Afternoon/Evening slots, independent
-- of technician working hours) are the replacement for the geometry system
-- this removes — see appointment_slots below.

-- ── 1. Appointment slots (Task 2/3) ──────────────────────────────────────
create table public.appointment_slots (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  start_time time not null,
  end_time time not null,
  is_active boolean not null default true,
  -- Optional admin override cap (spec: "future scalability"). Null = no
  -- manual cap — bookability is governed by real technician availability at
  -- assignment time (see book_service_ticket below), not a guessed number.
  max_bookings_per_slot integer,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_time < end_time)
);

create index appointment_slots_org_id_idx on public.appointment_slots (org_id);

alter table public.appointment_slots enable row level security;

-- Same shape as products_select_org/spares_select_org: every org member
-- (customers included) needs to read active slots to book against them.
create policy appointment_slots_select_org on public.appointment_slots for select using (org_id = public.current_org_id());
create policy appointment_slots_write_master on public.appointment_slots for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_appointment_slots after insert or update or delete on public.appointment_slots for each row execute function public.audit_master_change();

-- Seed the three fixed periods the spec calls for, for every existing org —
-- admin can retime/rename/deactivate/add more from here on, but every org
-- starts with a sensible default instead of an empty list that can't be
-- booked against.
insert into public.appointment_slots (org_id, name, start_time, end_time, sort_order)
select id, 'Morning', '08:00'::time, '12:00'::time, 1 from public.organizations
union all
select id, 'Afternoon', '12:00'::time, '16:00'::time, 2 from public.organizations
union all
select id, 'Evening', '16:00'::time, '20:00'::time, 3 from public.organizations;

-- ── 2. appointments: live slot link + stale-booking follow-up flag ──────
-- `slot_id` is the live link (Task 3: "if admin changes timings, updated
-- timings must automatically appear everywhere" — join through this, don't
-- freeze the slot's times into scheduled_at). Nullable: existing bookings
-- and non-slot flows (AMC/warranty auto-visits, admin's own NewComplaintPage
-- flow) keep working unchanged with slot_id null.
alter table public.appointments add column if not exists slot_id uuid references public.appointment_slots (id) on delete set null;
create index if not exists appointments_slot_id_idx on public.appointments (slot_id);

-- Set once by resolve_stale_bookings() below when a booking's day genuinely
-- ends with no technician ever assigned — drives the customer-facing
-- "technician will visit tomorrow as priority / telecaller will call you"
-- message (Task 4/5) instead of a premature bump at booking time.
alter table public.appointments add column if not exists follow_up_flagged_at timestamptz;

-- ── 3. book_service_ticket — accept the requested date+slot unconditionally ──
-- Signature change (p_available_from/p_available_to/p_unavailable_windows
-- replaced by p_scheduled_date/p_slot_id) — DROP required since this isn't a
-- compatible append-only change. customerApp.ts is the only caller.
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

grant execute on function public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, date, uuid
) to authenticated;

-- ── 4. resolve_stale_bookings — the actual Task 4 escalation ────────────
-- Resolve-on-view (same pattern as resolve_purchase_quote_requests — no
-- pg_cron in this stack): called opportunistically whenever the customer or
-- admin dashboards load. Idempotent via follow_up_flagged_at (only acts
-- once per appointment). A booking's day has "ended" when either its date
-- is strictly in the past, or it's today and the current time is past the
-- latest active slot's end time for this org.
create or replace function public.resolve_stale_bookings(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_local timestamp;
  v_last_slot_end time;
  v_count integer := 0;
  v_appt record;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'resolve_stale_bookings: org mismatch';
  end if;

  v_now_local := now() at time zone 'Asia/Kolkata';
  select max(end_time) into v_last_slot_end from public.appointment_slots where org_id = p_org_id and is_active = true;

  for v_appt in
    select a.id as appointment_id, a.ticket_id
    from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    where a.org_id = p_org_id
      and a.follow_up_flagged_at is null
      and a.technician_id is null
      and a.status = 'scheduled'
      and st.status = 'open'
      and (
        (a.scheduled_at at time zone 'Asia/Kolkata')::date < v_now_local::date
        or (
          (a.scheduled_at at time zone 'Asia/Kolkata')::date = v_now_local::date
          and v_last_slot_end is not null
          and v_now_local::time > v_last_slot_end
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
