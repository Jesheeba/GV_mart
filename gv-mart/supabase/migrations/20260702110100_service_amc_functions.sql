-- Phase 6 (ADM-09..13): Service, scheduling, AMC/Warranty — RPCs.
--
-- All SECURITY DEFINER + explicit is_ops_staff()/is_sales_staff() checks
-- inside, same rationale as create_sale (20260702100100): these functions
-- touch tables across ops-only RLS boundaries (appointments, service_visits,
-- notifications) from a single call, so authorization is re-implemented
-- explicitly here rather than relying on RLS mid-function.

-- ── Auto-detect ticket type (Design Deltas §19 / ADM-10) ────────────────
-- "Auto service-type (AMC / Warranty / Paid) decided from customer address,
-- product, brand, model; staff cannot choose Paid by hand." Simplified to
-- product-level matching (no address/brand/model narrowing beyond product,
-- since warranties/amc_contracts are keyed by product_id, not brand/model
-- individually) — an active AMC contract wins over a warranty if both are
-- present (AMC is the broader, ongoing coverage), else warranty, else paid.
create or replace function public._detect_ticket_type(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid
)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_amc amc_contracts;
  v_warranty warranties;
begin
  if p_product_id is not null then
    select * into v_amc from public.amc_contracts
    where org_id = p_org_id and customer_id = p_customer_id and product_id = p_product_id
      and status in ('active', 'due_soon') and expiry_date >= current_date
    order by expiry_date desc limit 1;

    if v_amc.id is not null then
      return jsonb_build_object(
        'type', 'amc', 'reason_key', 'service.newComplaint.typeReasonAmc',
        'amc_contract_id', v_amc.id, 'amc_expiry_date', v_amc.expiry_date, 'amc_start_date', v_amc.start_date
      );
    end if;

    select * into v_warranty from public.warranties
    where org_id = p_org_id and customer_id = p_customer_id and product_id = p_product_id
      and expiry_date >= current_date
    order by expiry_date desc limit 1;

    if v_warranty.id is not null then
      return jsonb_build_object(
        'type', 'warranty', 'reason_key', 'service.newComplaint.typeReasonWarranty',
        'warranty_id', v_warranty.id, 'warranty_expiry_date', v_warranty.expiry_date, 'warranty_start_date', v_warranty.start_date
      );
    end if;
  end if;

  return jsonb_build_object('type', 'paid', 'reason_key', 'service.newComplaint.typeReasonPaid');
end;
$$;

grant execute on function public._detect_ticket_type(uuid, uuid, uuid) to authenticated;

-- ── Create Complaint (ADM-10) ────────────────────────────────────────────
-- Creates the ticket with server-detected type + computed sla_due_at
-- (never trusts a client-supplied type — Design Deltas §19: "staff cannot
-- choose Paid by hand"), then optionally an appointment, then optionally
-- runs the same auto-assign engine as auto_assign_ticket below.
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
  p_auto_assign boolean
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
    now() + make_interval(hours => v_sla_hours)
  )
  returning id into v_ticket_id;

  if p_appointment_mode is not null then
    if p_appointment_mode = 'datetime' and p_scheduled_at is not null then
      if p_scheduled_at::time < v_settings.work_start or p_scheduled_at::time > v_settings.work_end then
        raise exception 'create_complaint_ticket: appointment time is outside working hours (% - %)', v_settings.work_start, v_settings.work_end;
      end if;
    end if;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled')
    returning id into v_appointment_id;
  end if;

  if p_auto_assign and v_appointment_id is not null then
    v_assign_result := public.auto_assign_ticket(v_ticket_id);
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'appointment_id', v_appointment_id,
    'detected_type', v_detected,
    'assign_result', v_assign_result
  );
end;
$$;

grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean
) to authenticated;

-- ── Auto-assign engine (ADM-11) ──────────────────────────────────────────
-- "availability + location + priority + customer availability". Ranking,
-- best candidate first:
--   1. on_duty technicians only ("availability")
--   2. no current open appointment (the one-open-appointment rule below)
--   3. nearest by last known location to the ticket's address, when both
--      have coordinates ("location") — technician_locations most-recent row
--   4. among ties, whoever has fewer appointments scheduled today (spreads
--      load / respects "customer availability" indirectly by not overloading
--      one tech's day)
-- Priority itself doesn't change *which* technician is picked (the ticket's
-- own priority already ordered which tickets get assigned first by the
-- caller/queue) — but very_urgent tickets skip the "customer availability"
-- appointment-mode nuance and are eligible for immediate (mode='always')
-- assignment same as any other. `for update skip locked` (same pattern as
-- Phase 5's simple version) makes concurrent calls fall through gracefully
-- instead of racing the one-open-appointment unique index.
create or replace function public.auto_assign_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_ticket service_tickets;
  v_appointment appointments;
  v_addr addresses;
  v_tech_id uuid;
  v_tech_count integer;
begin
  if not public.is_ops_staff() then
    raise exception 'auto_assign_ticket: only master or operation_admin may assign';
  end if;

  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'auto_assign_ticket: ticket % not found', p_ticket_id;
  end if;
  v_org_id := v_ticket.org_id;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'auto_assign_ticket: org mismatch';
  end if;

  select * into v_appointment from public.appointments
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress')
  order by created_at desc limit 1;
  if v_appointment.id is null then
    raise exception 'auto_assign_ticket: ticket % has no open appointment to assign', p_ticket_id;
  end if;
  if v_appointment.technician_id is not null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyAssigned');
  end if;

  if v_ticket.address_id is not null then
    select * into v_addr from public.addresses where id = v_ticket.address_id;
  end if;

  -- Candidate ranking: on-duty, no open appointment, nearest last-known
  -- location to the ticket address (if we have coordinates for both),
  -- fewest appointments already scheduled today as the final tiebreaker.
  select t.id into v_tech_id
  from public.technicians t
  left join lateral (
    select tl.lat, tl.lng
    from public.technician_locations tl
    where tl.technician_id = t.id
    order by tl.recorded_at desc
    limit 1
  ) loc on true
  left join lateral (
    select count(*) as cnt
    from public.appointments a2
    where a2.technician_id = t.id
      and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
  ) today on true
  where t.org_id = v_org_id
    and t.is_on_duty = true
    and not exists (
      select 1 from public.appointments a
      where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
    )
  order by
    -- nulls (no location fix yet) sort last, closest first
    case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
      then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
      else null
    end asc nulls last,
    coalesce(today.cnt, 0) asc,
    t.created_at asc
  for update skip locked
  limit 1;

  if v_tech_id is null then
    select count(*) into v_tech_count from public.technicians where org_id = v_org_id and is_on_duty = true;
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      v_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
      format('No free technician is available for ticket %s (%s on-duty).', p_ticket_id, v_tech_count), p_ticket_id
    );
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$$;

grant execute on function public.auto_assign_ticket(uuid) to authenticated;

-- ── Manual assign / drag-to-reassign (ADM-11) ────────────────────────────
-- Used both for the initial manual "Assign" action and for drag-to-reassign
-- on the per-technician timeline. Enforces the same one-open-appointment
-- rule as the DB unique index but raises a friendly conflict error first
-- (Design Deltas §22 / BuildSpec: "conflict warning") instead of letting the
-- caller hit a raw unique-constraint violation. Also enforces "no two
-- simultaneous appointments per customer" (BuildSpec ADM-11) by rejecting a
-- reassignment that would create a second open appointment for the same
-- customer at an overlapping time.
create or replace function public.assign_ticket_technician(
  p_appointment_id uuid,
  p_technician_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_appointment appointments;
  v_ticket service_tickets;
  v_conflict_appt_id uuid;
  v_customer_conflict_id uuid;
begin
  if not public.is_ops_staff() then
    raise exception 'assign_ticket_technician: only master or operation_admin may assign';
  end if;

  select * into v_appointment from public.appointments where id = p_appointment_id;
  if v_appointment.id is null then
    raise exception 'assign_ticket_technician: appointment % not found', p_appointment_id;
  end if;
  v_org_id := v_appointment.org_id;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'assign_ticket_technician: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = v_org_id) then
    raise exception 'assign_ticket_technician: technician % not found', p_technician_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_appointment.ticket_id;

  -- v2.2 §6.4: "one person can't have two open appointments" — surfaced as a
  -- conflict the caller can inspect/force past rather than a bare DB error.
  select a.id into v_conflict_appt_id
  from public.appointments a
  where a.technician_id = p_technician_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id;

  if v_conflict_appt_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.technicianBusy', 'conflict_appointment_id', v_conflict_appt_id
    );
  end if;

  -- BuildSpec ADM-11: "no two simultaneous appointments per customer" —
  -- block assigning a second technician to the same customer while another
  -- of that customer's tickets already has an open appointment (regardless
  -- of technician), unless forced.
  select a.id into v_customer_conflict_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  where st.customer_id = v_ticket.customer_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id
    and st.id <> v_ticket.id;

  if v_customer_conflict_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.customerBusy', 'conflict_appointment_id', v_customer_conflict_id
    );
  end if;

  -- Forced reassignment: bump whoever currently holds that technician's open
  -- slot back to unassigned so the unique index never trips.
  if p_force and v_conflict_appt_id is not null then
    update public.appointments set technician_id = null where id = v_conflict_appt_id;
    update public.service_tickets st set status = 'open'
      from public.appointments a where a.id = v_conflict_appt_id and st.id = a.ticket_id;
  end if;

  update public.appointments set technician_id = p_technician_id where id = p_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_appointment.ticket_id and status = 'open';

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_org_id, p.id, 'appointment_assigned', 'Job assigned', format('Ticket %s assigned to you.', v_appointment.ticket_id), p_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$$;

grant execute on function public.assign_ticket_technician(uuid, uuid, boolean) to authenticated;

-- ── Unlock next appointment only after current completes (ADM-11) ───────
-- Called when a visit/appointment is marked completed (Phase 7's technician
-- app will call this too). Not required to unlock anything explicitly since
-- the one-open-appointment unique index is scoped to status IN
-- (scheduled, in_progress) — completing frees the slot automatically. This
-- helper just centralizes "mark this appointment completed" so both admin
-- (manual close) and technician (Phase 7) share one code path with the
-- correct status transition and audit trail.
create or replace function public.complete_appointment(p_appointment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_ticket_id uuid;
begin
  if not (public.is_ops_staff() or public.current_technician_id() is not null) then
    raise exception 'complete_appointment: not authorized';
  end if;

  select org_id, ticket_id into v_org_id, v_ticket_id from public.appointments where id = p_appointment_id;
  if v_org_id is null then
    raise exception 'complete_appointment: appointment % not found', p_appointment_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'complete_appointment: org mismatch';
  end if;

  update public.appointments set status = 'completed' where id = p_appointment_id;
  update public.service_tickets set status = 'completed' where id = v_ticket_id;
end;
$$;

grant execute on function public.complete_appointment(uuid) to authenticated;

-- ── Sell AMC (ADM-12/13) ──────────────────────────────────────────────────
-- "On AMC sale auto-create the year's scheduled appointments." visits_per_year
-- (already modeling "service every N months") drives how many scheduled
-- (mode='datetime', status='scheduled', unassigned) appointments get created
-- across the contract's first year, evenly spaced. Each spawns its own
-- 'amc'-typed service_ticket (₹0 charge is enforced later at visit-billing
-- time in Phase 7, not here — this only schedules the visits).
-- RO-only is re-validated here (not just in create_sale) since this is a
-- second, independent entry point for AMC sales (ADM-12 "Sell AMC" button,
-- not tied to a product sale).
create or replace function public.sell_amc_plan(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_start_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan amc_plans;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
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

  v_expiry := p_start_date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  -- Schedule this first year's visits (Design Deltas §17: "AMC
  -- auto-schedules a service every 3 months, with a description").
  v_visit_date := p_start_date;
  for i in 1..v_plan.visits_per_year loop
    v_visit_date := p_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel
    ) values (
      p_org_id, p_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_plan.visits_per_year), v_plan.name,
      'amc', 'normal', 'open', 'call'
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled')
    returning id into v_appointment_id;
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date) to authenticated;

-- ── AMC/warranty status refresh (ADM-12 status chips active/due-soon/expired) ─
-- Pure function so the UI can also compute this client-side for display, but
-- centralizing here lets a future scheduled job (pg_cron) call it to keep
-- amc_contracts.status current without a UI visit. amc_book_window_days
-- (already in settings, used by the Customer App's self-book gate) doubles
-- as the "due soon" lookahead window — one admin-set number, two related
-- uses, no new setting needed.
create or replace function public.refresh_amc_statuses(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window integer;
begin
  if not public.is_ops_staff() then
    raise exception 'refresh_amc_statuses: only master or operation_admin may run this';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'refresh_amc_statuses: org mismatch';
  end if;

  select amc_book_window_days into v_window from public.settings where org_id = p_org_id;
  v_window := coalesce(v_window, 15);

  update public.amc_contracts
  set status = case
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end
  where org_id = p_org_id and status is distinct from (case
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end::amc_status);
end;
$$;

grant execute on function public.refresh_amc_statuses(uuid) to authenticated;
