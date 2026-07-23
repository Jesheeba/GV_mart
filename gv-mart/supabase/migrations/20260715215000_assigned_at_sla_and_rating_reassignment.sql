-- Logic 3 (assigned-date-based SLA reset) + Logic 1/2 (rating-based
-- technician reassignment for standard service tickets only).
--
-- Logic 3: service_tickets has no assigned_at column today — sla_due_at is
-- only ever stamped at ticket *creation* (book_service_ticket,
-- create_complaint_ticket). The moment a technician is actually assigned
-- should reset the SLA clock (assigned_at = now(), sla_due_at recomputed
-- from that moment using the same priority-based sla_hours_* lookup), for
-- BOTH the auto-assign engine and the admin's manual "Assign"/drag-reassign
-- picker (assign_ticket_technician).
--
-- Logic 1/2: for standard (non-AMC) service tickets only, before falling
-- back to the normal nearest/least-loaded candidate ranking, check the
-- customer's most recently completed prior ticket's technician + rating:
--   - prior rating >= 4 stars: prefer sending the SAME technician again
--     (if still on-duty and free) — "customer liked them, keep the match".
--   - prior rating <= 3 stars: avoid that technician; instead pick whoever
--     currently has the HIGHEST average rating among on-duty/free techs —
--     "customer had a bad experience, escalate to a better-rated one".
--   - no prior ticket, or prior visit unrated: no rating-based override,
--     fall through to the existing distance/load ranking unchanged.
-- AMC visit-scheduling loops (sell_amc_plan, renew_amc_plan, create_sale's
-- AMC add-on) are NOT "standard service tickets" and must keep using the
-- plain nearest/least-loaded ranking only — they pass the new
-- p_skip_rating_logic => true.
--
-- IMPORTANT Postgres overload-resolution note: _auto_assign_ticket_internal
-- currently exists ONLY as a 2-argument function
-- (p_ticket_id uuid, p_org_id uuid). Naively doing
-- `create or replace function _auto_assign_ticket_internal(p_ticket_id uuid,
-- p_org_id uuid, p_skip_rating_logic boolean default false)` would NOT
-- replace that function — a different argument COUNT is a different
-- signature to Postgres, so the old 2-arg function would keep existing
-- alongside a brand-new 3-arg overload. Every existing 2-argument call site
-- (book_service_ticket, and auto_assign_ticket's
-- `public._auto_assign_ticket_internal(p_ticket_id, v_org_id)`) would then
-- face two viable candidates (the exact-arity 2-arg function, and the 3-arg
-- function with its trailing default filled in) and Postgres does not
-- reliably prefer the new one — in practice this either raises "function is
-- not unique" or silently keeps resolving to the OLD, unmodified 2-arg
-- function, meaning the two most important "standard service ticket" paths
-- (staff manual/auto-assign and customer self-booking) would silently never
-- get the new rating logic or the assigned_at/SLA reset. So: drop the old
-- 2-arg signature first, then create the 3-arg version — leaving exactly one
-- overload, so 2-arg callers correctly fall through to the new default
-- (p_skip_rating_logic = false, i.e. they DO get the new behavior, which is
-- what we want for those two paths).

alter table public.service_tickets add column if not exists assigned_at timestamptz;

drop function if exists public._auto_assign_ticket_internal(uuid, uuid);

create or replace function public._auto_assign_ticket_internal(
  p_ticket_id uuid,
  p_org_id uuid,
  p_skip_rating_logic boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket service_tickets;
  v_appointment appointments;
  v_addr addresses;
  v_tech_id uuid;
  v_tech_count integer;
  v_prior_ticket_id uuid;
  v_prior_tech_id uuid;
  v_prior_stars numeric(2,1);
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % not found', p_ticket_id;
  end if;

  select * into v_appointment from public.appointments
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress')
  order by created_at desc limit 1;
  if v_appointment.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % has no open appointment to assign', p_ticket_id;
  end if;
  if v_appointment.technician_id is not null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyAssigned');
  end if;

  if v_ticket.address_id is not null then
    select * into v_addr from public.addresses where id = v_ticket.address_id;
  end if;

  -- Logic 1/2: rating-based reassignment, standard service tickets only
  -- (AMC visit-scheduling loops pass p_skip_rating_logic => true and never
  -- reach this block).
  if not p_skip_rating_logic then
    select st2.id into v_prior_ticket_id
    from public.service_tickets st2
    where st2.customer_id = v_ticket.customer_id and st2.id <> p_ticket_id and st2.status = 'completed'
    order by st2.updated_at desc limit 1;

    if v_prior_ticket_id is not null then
      select sv.technician_id, r.stars into v_prior_tech_id, v_prior_stars
      from public.service_visits sv
      left join public.ratings r on r.visit_id = sv.id
      where sv.ticket_id = v_prior_ticket_id
      order by sv.timer_start desc limit 1;
    end if;

    if v_prior_stars >= 4 and v_prior_tech_id is not null then
      select t.id into v_tech_id
      from public.technicians t
      where t.id = v_prior_tech_id and t.org_id = p_org_id and t.is_on_duty = true
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      for update of t skip locked;
    elsif v_prior_stars is not null and v_prior_stars <= 3 then
      select t.id into v_tech_id
      from public.technicians t
      where t.org_id = p_org_id and t.is_on_duty = true
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      order by (
        select avg(r2.stars) from public.ratings r2
        join public.service_visits sv2 on sv2.id = r2.visit_id
        where sv2.technician_id = t.id
      ) desc nulls last
      for update of t skip locked
      limit 1;
    end if;
  end if;

  -- Candidate ranking: on-duty, no open appointment, nearest last-known
  -- location to the ticket address (if we have coordinates for both),
  -- fewest appointments already scheduled today as the final tiebreaker.
  -- Only runs when the rating logic above (if any) didn't already pick a
  -- technician.
  if v_tech_id is null then
    select t.id into v_tech_id
    from public.technicians t
    left join lateral (
      select tl.lat, tl.lng from public.technician_locations tl
      where tl.technician_id = t.id order by tl.recorded_at desc limit 1
    ) loc on true
    where t.org_id = p_org_id
      and t.is_on_duty = true
      and not exists (
        select 1 from public.appointments a
        where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
      )
    order by
      case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
        then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
        else null
      end asc nulls last,
      (
        select count(*) from public.appointments a2
        where a2.technician_id = t.id and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ) asc,
      t.created_at asc
    for update of t skip locked
    limit 1;
  end if;

  if v_tech_id is null then
    select count(*) into v_tech_count from public.technicians where org_id = p_org_id and is_on_duty = true;
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
      format('No free technician is available for ticket %s (%s on-duty).', p_ticket_id, v_tech_count), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  -- Logic 3: reset the SLA clock from the moment of assignment, not just
  -- ticket creation.
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = p_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$$;

-- Intentionally NOT granted to authenticated: only ever called from other
-- SECURITY DEFINER functions (auto_assign_ticket, book_service_ticket,
-- sell_amc_plan, renew_amc_plan, create_sale), never directly by a client.
-- auto_assign_ticket(p_ticket_id) and book_service_ticket(...) both call
-- this with exactly 2 positional arguments and are intentionally NOT
-- recreated in this migration — now that the old 2-arg overload is dropped,
-- those calls resolve to this 3-arg function with p_skip_rating_logic
-- defaulting to false, which is exactly the desired behavior (they ARE
-- "standard service ticket" paths and should get the new rating logic +
-- SLA reset).

-- ── sell_amc_plan: verbatim body from 20260715120000, only change is the
-- auto-assign call now explicitly skips the new rating logic (AMC visits
-- are not "standard service tickets") ──────────────────────────────────────
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

  v_expiry := p_start_date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  -- Schedule visits across the FULL contract duration, not just the first
  -- year (Design Deltas §17: "AMC auto-schedules a service every N months"
  -- for the whole contract). Each visit is auto-assigned a technician
  -- immediately, same as any other ticket the ops side creates.
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
    values (p_org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled')
    returning id into v_appointment_id;

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

-- ── renew_amc_plan: verbatim body from 20260715120000, same p_skip_rating_logic
-- => true change ──────────────────────────────────────────────────────────
create or replace function public.renew_amc_plan(
  p_org_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_plan amc_plans;
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

  select * into v_settings from public.settings where org_id = p_org_id;

  -- Design Deltas §38 / CUST-03: self-booking only within the admin window.
  -- A first-time AMC (no existing contract for this product) is always
  -- allowed — the window only gates *renewal* of an existing contract.
  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > current_date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  v_start_date := greatest(current_date, coalesce(v_existing.expiry_date, current_date));
  v_expiry := v_start_date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'customer_app', v_contract_id
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) — payment ref %s', v_plan.name, v_plan.years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

-- ── create_sale: verbatim body from 20260715120000, same p_skip_rating_logic
-- => true change in the AMC add-on loop only ──────────────────────────────
create or replace function public.create_sale(
  p_org_id uuid,
  p_customer_id uuid,
  p_cart jsonb,
  p_quotation_id uuid default null
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
  -- v2.2 §6.1: technician up to 5% needs nothing extra, 5-10% needs a
  -- master's approval (below), above the admin max is blocked outright.
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

  -- ── Spares bill ──────────────────────────────────────────────────────
  v_spare_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'spare', p_cart -> 'spare_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  -- ── Product bill (two-bill rule: spares and products never share one) ──
  v_product_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'product', p_cart -> 'product_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  -- Per-product warranty + installation (ADM-06). Only meaningful once the
  -- product invoice exists, since both link back to it via invoice_id.
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
      end if;

      if coalesce(v_item.installation, false) then
        insert into public.service_tickets (
          org_id, customer_id, product_id, brand_id, model_id,
          name_of_complaint, nature_of_complaint, type, priority, status, channel, invoice_id
        )
        select p_org_id, p_customer_id, v_item.item_id, p.brand_id, p.model_id,
               'Installation', 'New product installation', 'installation', 'normal', 'open', 'walk_in', v_product_invoice.id
        from public.products p where p.id = v_item.item_id
        returning id into v_ticket_id;
        v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

        -- Simple auto-assign for Phase 5: first on-duty technician with no
        -- other active appointment (the full availability/location/priority
        -- engine is Phase 6/7). `for update skip locked` makes a concurrent
        -- sale racing for the same technician fall through to "unassigned"
        -- instead of aborting on the one-open-appointment unique index.
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

  -- ── AMC add-on (RO only) ─────────────────────────────────────────────
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

    v_amc_discount := round(v_amc_plan.price * v_discount_percent / 100, 2);
    v_amc_gst := round((v_amc_plan.price - v_amc_discount) * v_settings.gst_rate / 100, 2);
    v_amc_total := v_amc_plan.price - v_amc_discount + v_amc_gst;

    insert into public.invoices (
      org_id, customer_id, type, subtotal, discount, gst, total,
      payment_method, txn_id, payment_description, payment_status
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_plan.price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid'
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

    -- A plan's own included gift (e.g. a tier that bundles a water bottle)
    -- is distinct from the general above-threshold gift offer below.
    if v_amc_plan.gift_id is not null then
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_amc_invoice.id, v_amc_plan.gift_id);
    end if;

    -- This block previously created the amc_contracts row and stopped — no
    -- visit was ever scheduled for a product-sale AMC add-on. Mirrors
    -- sell_amc_plan/renew_amc_plan's fixed full-contract-duration scheduling
    -- loop, including auto-assign, so this entry point produces the same
    -- scheduled + assigned visits a standalone AMC sale gets.
    select a.id into v_amc_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

    v_amc_visit_date := current_date;
    for i in 1..v_amc_total_visits loop
      v_amc_visit_date := current_date + make_interval(months => v_amc_interval_months * i);
      exit when v_amc_visit_date > v_amc_expiry;

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, contract_id
      ) values (
        p_org_id, p_customer_id, v_amc_address_id, v_amc_product_id,
        format('AMC scheduled service %s of %s', i, v_amc_total_visits), v_amc_plan.name,
        'amc', 'normal', 'open', 'walk_in', v_amc_contract_id
      )
      returning id into v_amc_ticket_id;
      v_ticket_ids := array_append(v_ticket_ids, v_amc_ticket_id);

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
      values (p_org_id, v_amc_ticket_id, 'datetime', v_amc_visit_date::timestamptz + time '09:00', 'scheduled');

      perform public._auto_assign_ticket_internal(v_amc_ticket_id, p_org_id, p_skip_rating_logic => true);
    end loop;
  end if;

  -- ── Gift auto-offer (above threshold) ───────────────────────────────
  -- Attributed to one bill only (product > spare > amc priority) purely so
  -- it has a single home on the invoice list — discount/GST math above is
  -- unaffected either way. Re-validated server-side against the combined
  -- pre-discount subtotal; an ineligible gift_id from the client is simply
  -- dropped rather than failing the whole sale over a minor perk.
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

  -- ── Discount approval gate ───────────────────────────────────────────
  -- Billing isn't blocked on approval — the sale completes and this is a
  -- flag for a master to review after the fact (approvals queue, ADM-33).
  if v_discount_percent > v_settings.discount_tech_max and v_primary_invoice_id is not null then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_primary_invoice_id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if p_quotation_id is not null then
    update public.quotations set status = 'converted' where id = p_quotation_id and org_id = p_org_id;
  end if;

  return jsonb_build_object(
    'spare_invoice_id', v_spare_invoice.id,
    'product_invoice_id', v_product_invoice.id,
    'amc_invoice_id', v_amc_invoice.id,
    'warranty_ids', to_jsonb(v_warranty_ids),
    'ticket_ids', to_jsonb(v_ticket_ids),
    'approval_id', v_approval_id
  );
end;
$$;

-- ── assign_ticket_technician: verbatim body from 20260702110100, plus the
-- same assigned_at/sla_due_at recompute as the internal auto-assign engine
-- above (Logic 3: manual assignment/reassignment must also reset the SLA
-- clock). Signature is unchanged, so existing grants persist automatically ──
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
  v_settings settings;
  v_sla_hours numeric;
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

  -- Logic 3: manual assign / drag-to-reassign also resets the SLA clock,
  -- same settings-lookup + case pattern as the auto-assign engine. Not
  -- gated on the ticket's prior status (unlike the status='assigned'
  -- update above) — a forced reassignment of an already-assigned ticket
  -- should still reset the clock.
  select * into v_settings from public.settings where org_id = v_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_appointment.ticket_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$$;
