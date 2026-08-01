-- Fix: "technician finishes a visit, doesn't get pulled into the next
-- pending booking even though many are waiting today."
--
-- Root cause (confirmed by reading every call site of
-- _auto_assign_ticket_internal across all migrations): the auto-assign
-- engine only ever runs at TICKET-CREATION time (create_complaint_ticket,
-- book_service_ticket, sell_amc_plan, renew_amc_plan, create_sale's AMC/
-- installation branches). Nothing calls it again when a technician's slot
-- frees up. complete_appointment's own comment even says as much: "Not
-- required to unlock anything explicitly since the one-open-appointment
-- unique index ... completing frees the slot automatically" — true, but
-- freeing the slot is not the same as filling it with the next waiting job.
-- There is also no pg_cron / scheduled scan anywhere in this stack (see
-- 20260715300000_operational_alerts.sql and
-- 20260725120000_po_quotation_first_with_timeout_safeguard.sql, both of
-- which note pg_cron is unavailable) — so nothing polls for this either.
--
-- The actual moment a technician's appointment slot frees up is NOT
-- verify_visit_otp (that only ever sets service_visits.timer_end/
-- otp_verified — it never touches appointments.status or
-- service_tickets.status). It's create_service_invoice, called from the
-- earlier Invoice step, which already does:
--   update service_tickets set status = 'completed' ...
--   update appointments set status = 'completed' ...
-- (see 20260730100000_cost_price_tracking_functions.sql:392-394). That is
-- the true "this technician is now free" moment, and it happens before OTP
-- is even reached. The other close-out path, complete_appointment (admin
-- manual close), does the same status flip directly.
--
-- Fix shape: a new internal helper, _auto_assign_next_ticket_to_technician,
-- that is the mirror image of _auto_assign_ticket_internal — instead of
-- "given a ticket, find the best technician," it's "given a technician who
-- just freed up, find the best waiting ticket for them" — using the same
-- kind of filters (active, attendance-present, skill match, daily-capacity
-- headroom) and the same kind of ranking (priority first so nothing urgent
-- waits behind normal jobs, then nearest by last-known GPS, then oldest
-- ticket first so nothing starves). Only pulls tickets due today
-- (scheduled_at null or <= current_date) — future-dated tickets are left
-- for their own day's dispatch, same as the existing engine's split.
--
-- Wired into both close-out paths right after the appointment/ticket status
-- flip: create_service_invoice (the real technician-app completion path)
-- and complete_appointment (admin manual close). Not granted to
-- authenticated — internal helper only, exactly like
-- _auto_assign_ticket_internal.

create or replace function public._auto_assign_next_ticket_to_technician(
  p_org_id uuid,
  p_technician_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech technicians;
  v_appointment_id uuid;
  v_ticket_id uuid;
  v_ticket service_tickets;
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_tech from public.technicians where id = p_technician_id and org_id = p_org_id;
  if v_tech.id is null or not v_tech.is_active then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.technicianInactive');
  end if;

  -- Guard against a concurrent manual assign (or a second completion racing
  -- in) having already given this technician a job between their slot
  -- freeing up and this call running.
  if exists (
    select 1 from public.appointments a
    where a.technician_id = p_technician_id and a.status in ('scheduled', 'in_progress')
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyBusy');
  end if;

  -- Same attendance gate as _auto_assign_ticket_internal: don't hand new
  -- work to someone who has since checked out for the day.
  if not exists (
    select 1 from public.attendance a
    where a.technician_id = p_technician_id and a.org_id = p_org_id and a.date = current_date
      and a.check_in_at is not null and a.check_out_at is null
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.notPresent');
  end if;

  select a.id, a.ticket_id into v_appointment_id, v_ticket_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  left join public.addresses addr on addr.id = st.address_id
  left join lateral (
    select tl.lat, tl.lng from public.technician_locations tl
    where tl.technician_id = p_technician_id order by tl.recorded_at desc limit 1
  ) loc on true
  where a.org_id = p_org_id
    and a.technician_id is null
    and a.status in ('scheduled', 'in_progress')
    and st.status = 'open'
    and (a.scheduled_at is null or a.scheduled_at::date <= current_date)
    and (
      st.required_skill is null
      or v_tech.skills = '{}'
      or st.required_skill = any(v_tech.skills)
    )
    and coalesce((
      select sum(st2.estimated_duration_minutes)
      from public.appointments a2
      join public.service_tickets st2 on st2.id = a2.ticket_id
      where a2.technician_id = p_technician_id
        and a2.status in ('scheduled', 'in_progress')
        and a2.scheduled_at::date = coalesce(a.scheduled_at::date, current_date)
    ), 0) + coalesce(st.estimated_duration_minutes, 0) <= v_tech.daily_capacity_minutes
  order by
    case st.priority when 'very_urgent' then 0 when 'urgent' then 1 else 2 end asc,
    case when loc.lat is not null and addr.lat is not null and addr.lng is not null
      then point(loc.lng, loc.lat) <-> point(addr.lng, addr.lat)
      else null
    end asc nulls last,
    coalesce(a.scheduled_at, st.created_at) asc
  for update of a skip locked
  limit 1;

  if v_appointment_id is null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneWaiting');
  end if;

  update public.appointments set technician_id = p_technician_id where id = v_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_ticket_id;

  select * into v_ticket from public.service_tickets where id = v_ticket_id;
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', v_ticket_id), v_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id, 'appointment_id', v_appointment_id, 'ticket_id', v_ticket_id);
end;
$$;

-- Intentionally NOT granted to authenticated — internal helper only, called
-- from create_service_invoice and complete_appointment below (both already
-- SECURITY DEFINER with their own auth checks), never directly by a client.

-- ── create_service_invoice: verbatim body from
-- 20260730100000_cost_price_tracking_functions.sql, plus the auto-assign
-- call right after the appointment/ticket close-out (the real "this
-- technician just freed up" moment). ──────────────────────────────────────
create or replace function public.create_service_invoice(
  p_org_id uuid,
  p_visit_id uuid,
  p_service_charge numeric,
  p_discount_percent numeric,
  p_spares jsonb,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text,
  p_is_chargeable boolean -- false for warranty/amc: service_charge forced to 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'create_service_invoice: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_service_invoice: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null then
    raise exception 'create_service_invoice: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'create_service_invoice: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket is null then
    raise exception 'create_service_invoice: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_service_invoice: no settings row for org %', p_org_id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      if v_item.qty is null or v_item.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for spare %', v_item.spare_id;
      end if;
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      if v_price is null then
        raise exception 'create_service_invoice: spare % not found in org %', v_item.spare_id, p_org_id;
      end if;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      if p_is_chargeable or not v_is_spare_covered then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''), 'paid'
  ) returning * into v_invoice;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      update public.inventory
        set stock_qty = stock_qty - v_item.qty
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'van' and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;
      if v_new_stock is null then
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, 'service_visit', p_visit_id);
    end loop;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    update public.amc_contracts
      set next_service_date = (
        select min(a.scheduled_at::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  -- This technician's slot just freed up (their appointment flipped to
  -- 'completed' two statements above) — try to pull them straight into the
  -- next waiting job instead of leaving them idle until an admin notices.
  perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$$;

grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean) to authenticated;

-- ── complete_appointment: admin manual close-out, same auto-assign call ──
create or replace function public.complete_appointment(p_appointment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_ticket_id uuid;
  v_tech_id uuid;
begin
  if not (public.is_ops_staff() or public.current_technician_id() is not null) then
    raise exception 'complete_appointment: not authorized';
  end if;

  select org_id, ticket_id, technician_id into v_org_id, v_ticket_id, v_tech_id
  from public.appointments where id = p_appointment_id;
  if v_org_id is null then
    raise exception 'complete_appointment: appointment % not found', p_appointment_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'complete_appointment: org mismatch';
  end if;

  update public.appointments set status = 'completed' where id = p_appointment_id;
  update public.service_tickets set status = 'completed' where id = v_ticket_id;

  if v_tech_id is not null then
    perform public._auto_assign_next_ticket_to_technician(v_org_id, v_tech_id);
  end if;
end;
$$;

grant execute on function public.complete_appointment(uuid) to authenticated;
