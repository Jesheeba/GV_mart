-- Fix: multi-year AMC contracts only scheduled year 1's visits, and
-- amc_contracts.next_service_date went stale as soon as the first visit was
-- completed (never recalculated after contract creation).
--
-- Bug 1 (schedule loop): sell_amc_plan / renew_amc_plan create an
-- amc_contracts row spanning `years` years but the visit-scheduling loop
-- only ran `1..visits_per_year` — i.e. one year's worth of visits, ever. A
-- 3-year plan with visits_per_year=4 got 4 appointments total and years 2-3
-- got nothing. Fix: loop `1..(years * visits_per_year)` total visits, still
-- spaced every v_interval_months apart, still bounded by
-- `exit when v_visit_date > v_expiry`. The "service N of M" ticket label's
-- denominator is updated alongside the loop bound so it doesn't read
-- e.g. "5 of 4" once the loop covers the full term.
--
-- create_sale's AMC add-on block (product sale + bundled AMC) turned out to
-- have an even more severe version of the same gap: it created the
-- amc_contracts row and set next_service_date, but had NO scheduling loop
-- at all — zero visits were ever created for an AMC sold this way. Fixed by
-- adding the same full-contract-duration loop used in sell_amc_plan.
--
-- Bug 2 (stale next_service_date): next_service_date was written once at
-- contract creation and never touched again, so it kept showing a date that
-- had already passed once that visit was completed. Fixed in
-- create_service_invoice: right after a ticket is marked 'completed', if it
-- is an AMC-typed ticket linked to a contract (service_tickets.contract_id,
-- added in 20260713090000_amc_contract_id_on_tickets.sql), recompute that
-- contract's next_service_date to the earliest remaining
-- scheduled/in_progress appointment among the contract's own AMC tickets
-- (NULL once none remain). All three UI surfaces that display this
-- (admin AMC list, customer home, customer AMC page) read the column
-- directly, so this DB-side fix covers all of them without any frontend
-- change.

-- ── sell_amc_plan: same body as 20260713090000's version (which already
-- stamps contract_id), loop now covers the full contract term. ────────────
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

  -- Bug fix 20260715: schedule visits across the FULL contract duration, not
  -- just the first year (Design Deltas §17: "AMC auto-schedules a service
  -- every N months" for the whole contract, not year 1 only).
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
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date) to authenticated;

-- ── renew_amc_plan: same body as 20260713090000's version (which already
-- stamps contract_id), loop now covers the full contract term. ────────────
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

  -- Bug fix 20260715: schedule visits across the FULL contract duration, not
  -- just the first year (see sell_amc_plan above for the same fix).
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

-- ── create_sale: same body as 20260702100100_sales_phase5_functions.sql,
-- AMC add-on block now actually schedules visits (it previously created the
-- amc_contracts row and stopped — no loop existed here at all, so a
-- product-sale AMC add-on never got a single scheduled visit). ────────────
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

    -- Bug fix 20260715: this block previously created the amc_contracts row
    -- and stopped — no visit was ever scheduled for a product-sale AMC
    -- add-on (a more severe case of the same "AMC contract visits aren't
    -- scheduled" bug fixed in sell_amc_plan/renew_amc_plan above). Mirrors
    -- their fixed full-contract-duration scheduling loop so this entry
    -- point produces the same scheduled visits a standalone AMC sale gets.
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

grant execute on function public.create_sale(uuid, uuid, jsonb, uuid) to authenticated;

-- ── create_service_invoice: same body as
-- 20260702120000_technician_phase7_functions.sql, now recalculating the
-- linked AMC contract's next_service_date right after the ticket/appointment
-- are marked completed. ─────────────────────────────────────────────────────
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
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
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
  -- v2.2 §6.1/§6.7: technician up to 5% needs nothing extra, 5-10% needs a
  -- master's approval (below, non-blocking), above the admin max is a hard block.
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  -- v2.2 §6.2/§6.3: warranty/AMC visits cost the customer ₹0 (service charge
  -- forced server-side, never trusted from the client toggle).
  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  -- Pass 1: price every spare line from the master (server-side, never the
  -- client) and accumulate the subtotal. Warranty/AMC spares price at 0 but
  -- quantity is still recorded and inventory still deducts.
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
      if p_is_chargeable then
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

  -- Service charge line (only when actually chargeable and > 0). Modeled as
  -- an invoice_item against nothing tidy in the item_type enum (product |
  -- spare) to represent "labour" — so the charge lives on invoices.subtotal
  -- directly and only spares get line items. This keeps invoice_items
  -- strictly polymorphic over real catalog rows, matching Phase 5.
  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_price := case when p_is_chargeable then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      -- Atomic decrement — conditional UPDATE, mirrors create_sale exactly.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'van' and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;
      if v_new_stock is null then
        -- Fall back to warehouse stock if the technician's van stock isn't
        -- tracked separately for this item (seed data may only populate
        -- 'warehouse'; field ops still needs the sale to go through).
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

  -- Bug fix 20260715: amc_contracts.next_service_date was written once at
  -- contract creation and never recalculated, so it kept showing a date
  -- that had already passed once that visit was completed. Recompute it to
  -- the earliest remaining scheduled/in_progress appointment among this
  -- contract's own AMC-typed tickets (NULL once none remain — the contract
  -- is fully serviced for its term).
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

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$$;

grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean) to authenticated;
