-- Phase 8 (CUST-01..08): Customer App — RPCs.
--
-- Same shape as Phase 6/7's SECURITY DEFINER RPCs (20260701 service_amc /
-- technician_phase7 functions): these cross RLS boundaries that are
-- deliberately staff/technician-only (service_tickets write is
-- `is_ops_staff()`, amc_contracts write is `is_ops_staff()/is_sales_staff()`,
-- leads write beyond the customer's own row, notifications insert is
-- `is_ops_staff()`-only) so a plain customer-role caller cannot do these
-- writes directly — each RPC re-implements the narrow "is this MY row"
-- check explicitly instead of relying on RLS mid-function.

-- ── book_service_ticket (CUST-02) ────────────────────────────────────────
-- Guided chat/stepper booking. If p_product_id is null (customer doesn't
-- recognise their product/model/brand), the ticket is still created — v2.2
-- Design Deltas §36: "if unknown, skip and it's added to a service enquiry
-- automatically" — so this also drops a `leads` row (source='customer_app',
-- enquiry_type=null since it's a service enquiry not a marketing topic) when
-- product_id is null, functioning as that "service enquiry".
-- Coverage (paid/warranty/amc) is auto-detected server-side via the same
-- `_detect_ticket_type` helper Phase 6 already defined — never trusts a
-- client-sent type, matching Design Deltas §19 ("staff cannot choose Paid by
-- hand"; here, the customer never even sees a type choice at all).
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
  p_scheduled_at timestamptz
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
    now() + make_interval(hours => v_sla_hours)
  )
  returning id into v_ticket_id;

  if p_appointment_mode is not null then
    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled')
    returning id into v_appointment_id;
  end if;

  -- Design Deltas §36: unknown product -> also logged as a service enquiry lead.
  if p_product_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, status)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', 'new'
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'service_enquiry', p_name_of_complaint);
  end if;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'service_booked', 'New service booking from customer app',
    format('%s', p_name_of_complaint), v_ticket_id
  );

  return jsonb_build_object(
    'ticket_id', v_ticket_id, 'appointment_id', v_appointment_id,
    'detected_type', v_detected, 'lead_id', v_lead_id
  );
end;
$$;

grant execute on function public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz
) to authenticated;

-- ── submit_enquiry (CUST-04 Product Enquiry / CUST-05 Spare Enquiry) ────
-- Both screens create a `lead` for the calling customer. p_kind distinguishes
-- them purely for the lead_activities.type label (nothing schema-level
-- differs) — Product Enquiry's "Request quotation" and Spare Enquiry's
-- submit both funnel through here. enquiry_type is set for Product Enquiry's
-- topic chips (online/price/quality/customization/water_premium/budget) and
-- left null for Spare Enquiry (no topic chip concept there).
create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_lead_id uuid;
  v_note text;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'submit_customer_enquiry: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_customer_enquiry: org mismatch';
  end if;
  if p_kind not in ('product', 'spare') then
    raise exception 'submit_customer_enquiry: invalid kind %', p_kind;
  end if;

  insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, status)
  select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, 'new'
  from public.customers c where c.id = v_customer_id
  returning id into v_lead_id;

  v_note := coalesce(nullif(btrim(p_description), ''), '(no description)');
  if p_photo_url is not null and btrim(p_photo_url) <> '' then
    v_note := v_note || format(' [photo: %s]', p_photo_url);
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, p_kind || '_enquiry', v_note);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'sales_admin', 'enquiry_lead',
    case when p_kind = 'product' then 'New product enquiry' else 'New spare enquiry' end,
    v_note, v_lead_id
  );

  return v_lead_id;
end;
$$;

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text) to authenticated;

-- ── renew_amc_plan (CUST-03) ──────────────────────────────────────────────
-- v2.2: "in-app online payment via gateway — the ONLY place a payment
-- gateway is used." No real gateway credentials exist in this environment
-- (see build-notes at the call site in services/customerApp.ts) — this RPC
-- is the atomic "payment succeeded, now record the contract" half of that
-- flow. It re-validates the admin booking window server-side (never trusts
-- the client's "is it near renewal" check), re-validates RO-only, and
-- reuses the same visit-scheduling logic as staff-side `sell_amc_plan`
-- (Phase 6) so a self-renewed AMC gets its scheduled visits exactly like a
-- staff-sold one — duplicated here (not calling sell_amc_plan directly)
-- because that function hard-requires is_ops_staff()/is_sales_staff().
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

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;

  v_visit_date := v_start_date;
  for i in 1..v_plan.visits_per_year loop
    v_visit_date := v_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_plan.visits_per_year), v_plan.name,
      'amc', 'normal', 'open', 'customer_app'
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled');
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) — payment ref %s', v_plan.name, v_plan.years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.renew_amc_plan(uuid, uuid, uuid, text) to authenticated;

-- ── register_product_via_qr (CUST-06 "register-via-QR") ─────────────────
-- QR payload resolves to a product_id (scan decoding happens client-side —
-- this just validates + writes). Creates the warranty row for the customer's
-- own account using the product's warranty_months default, mirroring the
-- staff-side auto-warranty-on-sale behaviour from Phase 5 but customer-
-- triggered. serial_no is whatever the QR encodes (nullable — some products
-- may not carry one).
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

  return v_warranty_id;
end;
$$;

grant execute on function public.register_product_via_qr(uuid, uuid, text, date) to authenticated;
