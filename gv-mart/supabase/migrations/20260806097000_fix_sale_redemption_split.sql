-- Fix: create_sale()'s referral-point redemption capped the discount
-- against only the "primary" invoice of a multi-item cart (whichever of
-- spare/product/amc happened to be created first), while the frontend's
-- payableTotal() (src/app/admin/sales/types.ts) always assumed the discount
-- applied against the CART's combined total. When a cart produced 2+
-- invoices and the redeemed amount exceeded the primary invoice's own
-- total, the mismatch silently left the other invoice(s) underpaid/
-- "partial" even though staff had collected what the UI told them was the
-- full payable amount. It also debited the customer's full requested point
-- count even when the applied discount had been truncated, discarding the
-- unused value instead of returning it to their balance.
--
-- Fix: cap redemption to whole points the CART's combined total can
-- actually absorb (so the amount debited from `total` and the points
-- debited from the ledger always correspond exactly — no rounding/
-- truncation mismatch is possible), then spread that discount across every
-- invoice the cart produced using the same waterfall style already used a
-- few lines below for allocating the collected payment.

drop function if exists public.create_sale(uuid, uuid, jsonb, uuid, integer, uuid, numeric);

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
  v_max_redeemable_points integer;
  v_redeem_remaining numeric(12, 2);
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

  -- REDEMPTION FIX: cap to whole points the CART's combined total (every
  -- invoice the cart produced, not just the primary one) can actually
  -- absorb, so the dollar amount debited from invoice totals and the point
  -- count debited from the ledger always correspond exactly.
  if v_redeem_points > 0 then
    if v_primary_invoice_id is null then
      raise exception 'create_sale: cannot redeem referral points — the cart produced no invoice to apply them to';
    end if;

    v_combined_total := 0;
    for v_pay_invoice_id in
      select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
    loop
      select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
      v_combined_total := v_combined_total + v_pay_invoice_total;
    end loop;

    v_max_redeemable_points := floor(v_combined_total / v_settings.referral_point_value)::integer;
    v_redeem_points := least(v_redeem_points, v_max_redeemable_points);
    v_redeem_amount := round(v_redeem_points * v_settings.referral_point_value, 2);

    if v_redeem_points > 0 then
      v_redeem_remaining := v_redeem_amount;
      for v_pay_invoice_id in
        select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
      loop
        select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
        v_pay_amount := least(v_redeem_remaining, v_pay_invoice_total);
        update public.invoices set total = total - v_pay_amount where id = v_pay_invoice_id;
        v_redeem_remaining := v_redeem_remaining - v_pay_amount;
      end loop;

      insert into public.referral_points (org_id, customer_id, points, reason, ref_id)
      values (p_org_id, p_customer_id, -v_redeem_points, 'redeemed_on_sale', v_primary_invoice_id);
    else
      v_redeem_amount := 0;
    end if;
  end if;

  -- AMOUNT TRACKING: allocate the cart's single amount-paid figure across
  -- whichever of {spare, product, amc} invoices this cart actually
  -- produced, in creation order, using each invoice's CURRENT total (i.e.
  -- after the gift/redeem adjustments just above, which as of this fix may
  -- now span every invoice in the cart, not only the primary one — re-
  -- reading from the table rather than trusting the stale local
  -- v_*_invoice.total records is required here, not optional). Defaults to
  -- "fully paid" when the caller doesn't pass p_amount_paid, matching every
  -- prior release.
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
