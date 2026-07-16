-- Referral points can be earned (award_referral_points, RLS-visible via
-- referral_points_select_staff/_own) but there has never been any way to
-- spend them — the ledger only ever grows. This adds redemption at time of
-- sale: sales staff can apply a customer's current point balance as a flat
-- ₹ discount when billing them, valued at the admin-set
-- settings.referral_point_value (v2.2 §6.8, min ₹50/point).
--
-- RECONCILIATION NOTE: create_sale has been redefined twice since its
-- original Phase 5 body (20260702100100_sales_phase5_functions.sql):
--   - 20260715110000_amc_multiyear_scheduling_and_next_service_recalc.sql
--     fixed the AMC add-on to schedule visits across the full contract
--     duration instead of just year 1.
--   - 20260715120000_auto_assign_customer_and_amc_bookings.sql then added
--     `perform public._auto_assign_ticket_internal(...)` calls into that
--     same AMC add-on loop (and into sell_amc_plan/renew_amc_plan/
--     book_service_ticket), on top of the multi-year fix.
-- This migration is based on the LATEST merged body — 20260715120000's
-- version of create_sale — carrying both prior fixes forward untouched
-- (the full-duration visit-scheduling loop AND the auto-assign call inside
-- it) and only adding the redemption parameter/logic on top. Nothing about
-- the installation-technician assignment, AMC contract creation, gift
-- auto-offer, or discount-approval logic below is altered.
--
-- Money-math decision: settings.referral_point_value converts points to a
-- ₹ amount (v_redeem_amount). This is applied as a flat deduction against
-- the *total* (amount payable) of one designated invoice — the same
-- "product > spare > amc" v_primary_invoice_id this function already picks
-- for the gift auto-offer, just below where that variable is computed.
-- Redemption deliberately does NOT touch subtotal/discount/gst on that
-- invoice: it isn't a price discount (which would also shrink taxable
-- value) or a payment method, so subtotal/GST stay computed purely from the
-- percent-discount mechanism, and only `total` (what the customer actually
-- pays) drops by the redeemed amount — same shape as "paying part of the
-- bill with a gift card". Applying against a single designated invoice
-- (rather than splitting proportionally across up to three) is the
-- simplest approach that still guarantees "total money paid across all
-- invoices from this sale decreases by exactly v_redeem_amount" whenever
-- the sale is large enough to absorb it, without needing to prorate a
-- rounding-sensitive split across bills that already round independently.
--
-- The balance check (p_redeem_points <= actual ledger sum) is the
-- real-money guard and fails loudly (raises) rather than clamping — never
-- silently trust/adjust a client-sent redeem amount. Separately, the
-- *monetary* application is capped at the designated invoice's own total
-- so it can never drive that invoice negative; if a redemption is worth
-- more than the invoice it lands on (an edge case — the UI shows the live
-- ₹ value before submit, so this only bites if staff deliberately redeems
-- more than the sale is worth), the full p_redeem_points is still deducted
-- from the ledger, since the customer explicitly asked to spend that many
-- points and the deduction must match what was requested, not what
-- happened to fit.
--
-- Parameter count changes (p_redeem_points added), so — same as
-- 20260715200000_quotation_from_lead.sql did for create_quotation — the old
-- 4-arg overload is dropped first rather than left to linger ambiguously
-- alongside the new 5-arg one (a bare 4-arg call would otherwise resolve
-- against either, since the 5th param has a default).
drop function if exists public.create_sale(uuid, uuid, jsonb, uuid);

create or replace function public.create_sale(
  p_org_id uuid,
  p_customer_id uuid,
  p_cart jsonb,
  p_quotation_id uuid default null,
  p_redeem_points integer default 0
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

  -- ── Referral point redemption: validate against the real ledger up front ──
  -- The balance is recomputed here from referral_points itself, never
  -- trusted from whatever the client happens to be displaying — a mismatch
  -- (e.g. a stale balance shown in a UI that hasn't refetched) must fail
  -- the sale outright rather than silently redeem a different amount.
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

      perform public._auto_assign_ticket_internal(v_amc_ticket_id, p_org_id);
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

  -- ── Referral point redemption: apply the flat ₹ discount ────────────
  -- Same "one designated invoice" home as the gift offer just above. Capped
  -- at that invoice's own total so it can never go negative; the full
  -- v_redeem_points is still removed from the ledger below even if the
  -- monetary application had to be capped (see file header for reasoning).
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
    'approval_id', v_approval_id,
    'redeemed_points', v_redeem_points,
    'redeemed_amount', v_redeem_amount
  );
end;
$$;

grant execute on function public.create_sale(uuid, uuid, jsonb, uuid, integer) to authenticated;
