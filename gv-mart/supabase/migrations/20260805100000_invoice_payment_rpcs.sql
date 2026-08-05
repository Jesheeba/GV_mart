-- Amount tracking fix, Phase 1: stop hardcoding payment_status = 'paid' in
-- the 4 functions that create customer invoices. Each gains a new trailing
-- p_amount_paid numeric param (default null -> falls back to the invoice's
-- full total, i.e. "fully paid" stays the default behavior for any caller
-- not yet updated to pass a real value — see Phases 2-3 for the frontends).
-- payment_status is never accepted from the client; it's always derived
-- server-side via public._derive_payment_status() (20260805090000).
--
-- Each function's parameter list is growing by one, so the old signature
-- must be dropped first — CREATE OR REPLACE can't change a function's
-- argument types, only its body (same reason this codebase already does
-- `drop function if exists public.create_sale(uuid, uuid, jsonb, uuid);`
-- in 20260715213000_referral_points_redemption.sql and
-- 20260716140000_sales_income_attribution.sql when growing this same
-- function previously).

-- ── _sale_create_line_invoice: product/spare lines for the admin "New Sale" wizard ──

drop function if exists public._sale_create_line_invoice(
  uuid, uuid, invoice_type, jsonb, numeric, numeric, payment_method, text, text
);

create or replace function public._sale_create_line_invoice(
  p_org_id uuid,
  p_customer_id uuid,
  p_type invoice_type, -- 'product' or 'spare' only
  p_items jsonb, -- [{item_id, qty}, ...]
  p_discount_percent numeric,
  p_gst_rate numeric,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text,
  p_amount_paid numeric default null
)
returns invoices
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item_type item_type := p_type::text::item_type;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return null;
  end if;

  -- Pass 1: price every line from the master and accumulate the subtotal.
  for v_item in select * from jsonb_to_recordset(p_items) as x(item_id uuid, qty integer)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      raise exception '_sale_create_line_invoice: qty must be positive for item %', v_item.item_id;
    end if;

    if p_type = 'product' then
      select price into v_price from public.products where id = v_item.item_id and org_id = p_org_id;
    else
      select price into v_price from public.spares where id = v_item.item_id and org_id = p_org_id;
    end if;
    if v_price is null then
      raise exception '_sale_create_line_invoice: item % not found in org %', v_item.item_id, p_org_id;
    end if;

    v_subtotal := v_subtotal + (v_price * v_item.qty);
  end loop;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * p_gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception '_sale_create_line_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception '_sale_create_line_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, p_type, v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, p_txn_id, p_payment_description,
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid, auth.uid()
  ) returning * into v_invoice;

  -- Pass 2: same prices, now writing invoice_items and decrementing stock.
  for v_item in select * from jsonb_to_recordset(p_items) as x(item_id uuid, qty integer)
  loop
    if p_type = 'product' then
      select price, cost_price into v_price, v_cost from public.products where id = v_item.item_id and org_id = p_org_id;
    else
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.item_id and org_id = p_org_id;
    end if;

    v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

    insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
    values (p_org_id, v_invoice.id, v_item_type, v_item.item_id, v_item.qty, v_price, v_line_discount, v_cost);

    update public.inventory
      set stock_qty = stock_qty - v_item.qty
      where org_id = p_org_id and item_type = v_item_type and item_id = v_item.item_id
        and location = 'warehouse' and stock_qty >= v_item.qty
      returning stock_qty into v_new_stock;
    if v_new_stock is null then
      raise exception '_sale_create_line_invoice: insufficient stock for % % (need %)', v_item_type, v_item.item_id, v_item.qty;
    end if;

    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (p_org_id, v_item_type, v_item.item_id, -v_item.qty, 'sale', v_invoice.id);
  end loop;

  return v_invoice;
end;
$$;

-- ── create_sale: the admin "New Sale" wizard cart (spare/product/amc) ──

drop function if exists public.create_sale(uuid, uuid, jsonb, uuid, integer, uuid);

create or replace function public.create_sale(
  p_org_id uuid,
  p_customer_id uuid,
  p_cart jsonb,
  p_quotation_id uuid default null,
  p_redeem_points integer default 0,
  p_referred_by_technician_id uuid default null,
  p_amount_paid numeric default null -- whole-cart amount; allocated across whichever of {spare,product,amc} invoices the cart produces
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
  v_customer_name text; -- REFERRAL: only looked up if p_referred_by_technician_id is used
  v_combined_total numeric(12, 2); -- AMOUNT TRACKING: sum of every invoice's *current* total, after gift/redeem adjustments
  v_amount_paid_remaining numeric(12, 2);
  v_pay_invoice_id uuid;
  v_pay_invoice_total numeric(12, 2);
  v_pay_amount numeric(12, 2);
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

  -- REFERRAL (new): a walk-in sale has no quotation/lead to trace back to —
  -- if the sales staff picked a referring technician, mint one the same way
  -- sell_amc_plan_onsite does (inserted straight to 'won', there is no
  -- pipeline left to walk since this IS the completed conversion).
  if v_lead_id is null and p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Sales customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Walk-in sale, referred by technician');
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
        where t.org_id = p_org_id and t.is_active = true
          and exists (
            select 1 from public.attendance a
            where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
              and a.check_in_at is not null and a.check_out_at is null
          )
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
      payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_effective_price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid', v_amc_total, auth.uid()
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

  -- AMOUNT TRACKING: allocate the cart's single amount-paid figure across
  -- whichever of {spare, product, amc} invoices this cart actually
  -- produced, in creation order, using each invoice's CURRENT total (i.e.
  -- after the gift/redeem adjustments just above — v_redeem_amount only
  -- ever touches v_primary_invoice_id's total, so re-reading from the
  -- table rather than trusting the stale local v_*_invoice.total records
  -- is required here, not optional). Defaults to "fully paid" when the
  -- caller doesn't pass p_amount_paid, matching every prior release.
  v_combined_total := 0;
  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_combined_total := v_combined_total + v_pay_invoice_total;
  end loop;

  v_amount_paid_remaining := coalesce(p_amount_paid, v_combined_total);
  if v_amount_paid_remaining < 0 then
    raise exception 'create_sale: amount_paid cannot be negative';
  end if;
  if v_amount_paid_remaining > v_combined_total then
    raise exception 'create_sale: amount_paid (%) cannot exceed the combined invoice total (%)', v_amount_paid_remaining, v_combined_total;
  end if;

  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_pay_amount := least(v_amount_paid_remaining, v_pay_invoice_total);
    update public.invoices
      set amount_paid = v_pay_amount,
          payment_status = public._derive_payment_status(v_pay_amount, v_pay_invoice_total)
      where id = v_pay_invoice_id;
    v_amount_paid_remaining := v_amount_paid_remaining - v_pay_amount;
  end loop;

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

grant execute on function public.create_sale(uuid, uuid, jsonb, uuid, integer, uuid, numeric) to authenticated;

-- ── create_service_invoice: technician on-site service/spare completion ──

drop function if exists public.create_service_invoice(
  uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean
);

create or replace function public.create_service_invoice(
  p_org_id uuid,
  p_visit_id uuid,
  p_service_charge numeric,
  p_discount_percent numeric,
  p_spares jsonb,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text,
  p_is_chargeable boolean, -- false for warranty/amc: service_charge forced to 0
  p_amount_paid numeric default null
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
  v_amount_paid numeric(12, 2);
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

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid
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

grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric) to authenticated;

-- ── sell_amc_plan_onsite: technician on-site AMC sale ──

drop function if exists public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text);

create or replace function public.sell_amc_plan_onsite(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_method payment_method,
  p_txn_id text default null,
  p_payment_description text default null,
  p_amount_paid numeric default null
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
  v_amount_paid numeric(12, 2);
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

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'sell_amc_plan_onsite: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'sell_amc_plan_onsite: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'amc', v_effective_price, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid, auth.uid()
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

grant execute on function public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text, numeric) to authenticated;
