-- STEP 6.3 (Assignment spec Phase 5.1) — Finder credit payout, functions half.
-- Depends on 20260723130000 (service_tickets.lead_id column + the
-- 'finder_credit' incentive_type enum value, which cannot be referenced in
-- the same transaction it was added in).
--
-- CONVERSION PATH (build-audit finding, matching real code, not the Build
-- Order's guess of "src/services/customers.ts / admin/masters"): there is no
-- generic "convert lead to ticket" action anywhere in this codebase. The
-- only place a lead ever produces a service_tickets row is
-- create_sale(p_quotation_id) — quotations.lead_id already exists
-- (20260701090900_leads_automation.sql / 20260715200000_quotation_from_lead.sql)
-- so a quotation can be created from a lead, and create_sale is the sole
-- function that both reads quotations and inserts into service_tickets
-- (installation ticket, warranty-scheduled visits, AMC-scheduled visits).
-- So: create_sale resolves the source lead (if any) off the quotation and
-- stamps it onto every ticket the sale produces, and marks that lead 'won'
-- — the same status an admin can already set by hand from LeadDetailPanel,
-- now set automatically the moment a real paid conversion happens.

-- ── create_sale (canonical, 5-arg): verbatim body from
-- 20260716140000_sales_income_attribution.sql, with ONLY the lead
-- traceability additions below (search "FINDER CREDIT" for every change —
-- three ticket inserts gain `lead_id`, plus the new v_lead_id resolution
-- and the closing lead status update). Everything else — sold_by
-- attribution, referral redemption, AMC price_per_year, warranty quarterly
-- scheduling — is untouched. ─────────────────────────────────────────────
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
  v_warranty warranties;
  v_warranty_address_id uuid;
  v_warranty_total_visits integer;
  v_warranty_visit_date date;
  v_warranty_ticket_id uuid;
  v_amc_effective_price numeric(12, 2);
  v_lead_id uuid; -- FINDER CREDIT: source lead behind p_quotation_id, if any
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

  -- FINDER CREDIT: resolve the lead this sale traces back to (if the
  -- quotation was itself created from a lead) so every ticket this sale
  -- produces below can be stamped with it.
  if p_quotation_id is not null then
    select lead_id into v_lead_id from public.quotations where id = p_quotation_id and org_id = p_org_id;
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

        -- Proactive quarterly warranty visits (build-audit gap fix): same
        -- fixed-cadence scheduling as register_product_via_qr's customer
        -- self-registration path — this is the product-sale entry point for
        -- the same warranties table. p_skip_rating_logic => true, same
        -- reasoning as the AMC scheduled visits below (scheduled
        -- maintenance, not a standard-ticket rating-reassignment scenario).
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
          values (p_org_id, v_warranty_ticket_id, 'datetime', v_warranty_visit_date::timestamptz + time '09:00', 'scheduled');

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

    -- Fix (build audit): price off amc_plans.price_per_year (the source of
    -- truth as of 20260716130000_amc_price_per_year_and_covered_spares.sql)
    -- instead of the now-stale flat `price` column. No p_years parameter
    -- exists on this add-on (the New Sale cart never collects one), so this
    -- always prices the plan's own default `years` — falls back to `price`
    -- only as a defensive no-op for any plan row where price_per_year is
    -- somehow still null (shouldn't happen: backfilled for all existing
    -- rows, required going forward on the AMC Plans master form).
    v_amc_effective_price := coalesce(v_amc_plan.price_per_year * v_amc_plan.years, v_amc_plan.price);

    v_amc_discount := round(v_amc_effective_price * v_discount_percent / 100, 2);
    v_amc_gst := round((v_amc_effective_price - v_amc_discount) * v_settings.gst_rate / 100, 2);
    v_amc_total := v_amc_effective_price - v_amc_discount + v_amc_gst;

    insert into public.invoices (
      org_id, customer_id, type, subtotal, discount, gst, total,
      payment_method, txn_id, payment_description, payment_status, sold_by
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_effective_price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid', auth.uid()
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
        type, priority, status, channel, contract_id, lead_id
      ) values (
        p_org_id, p_customer_id, v_amc_address_id, v_amc_product_id,
        format('AMC scheduled service %s of %s', i, v_amc_total_visits), v_amc_plan.name,
        'amc', 'normal', 'open', 'walk_in', v_amc_contract_id, v_lead_id -- FINDER CREDIT
      )
      returning id into v_amc_ticket_id;
      v_ticket_ids := array_append(v_ticket_ids, v_amc_ticket_id);

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
      values (p_org_id, v_amc_ticket_id, 'datetime', v_amc_visit_date::timestamptz + time '09:00', 'scheduled');

      -- OVERLOAD FIX: this fix was originally applied (2026-07-15) to a
      -- 4-arg overload the app never actually called — see the OVERLOAD FIX
      -- note near the top of this migration. Re-applied here, on the real
      -- overload, for the first time.
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

    -- FINDER CREDIT: a real paid conversion happened — mark the source lead
    -- 'won' the same way an admin could already do by hand from
    -- LeadDetailPanel, so the lead pipeline reflects reality without
    -- needing a manual follow-up click. Harmless no-op when v_lead_id is
    -- null (quotation had no lead) or already 'won'.
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

grant execute on function public.create_sale(uuid, uuid, jsonb, uuid, integer) to authenticated;

-- ── technician_finder_conversions: finder-credit counterpart to
-- technician_attributed_revenue / technician_attributed_sales, same
-- signature/language/stability conventions. Counts DISTINCT completed
-- tickets in the period that trace back (service_tickets.lead_id) to a lead
-- this technician found (leads.owner_id) — regardless of which technician
-- actually performed the job, per the Phase 5.1 hard rule. "Completed" is
-- read the same way technician_attributed_revenue reads it: a service_visits
-- row with timer_end in range, not service_tickets.status/updated_at (no
-- completed_at column exists on service_tickets). ───────────────────────
create or replace function public.technician_finder_conversions(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(distinct v.ticket_id)::integer
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  join public.leads l on l.id = st.lead_id
  where v.org_id = p_org_id
    and st.org_id = p_org_id
    and st.lead_id is not null
    and l.owner_id = p_technician_id
    and st.status = 'completed'
    and v.timer_end is not null
    and v.timer_end >= date_trunc('month', p_period)
    and v.timer_end < date_trunc('month', p_period) + interval '1 month';
$$;

-- ── compute_incentives: verbatim body from
-- 20260716140000_sales_income_attribution.sql, only adding a
-- 'finder_credit' branch (same threshold/amount shape as every other
-- branch — the ADMIN sets threshold/amount via Masters > Incentives, no ₹
-- figure invented here; see build report). ───────────────────────────────
create or replace function public.compute_incentives(
  p_org_id uuid,
  p_period date
)
returns setof incentives_earned
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_metric numeric(12, 2);
  v_review_count integer;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and r.created_at >= date_trunc('month', v_period)
          and r.created_at < date_trunc('month', v_period) + interval '1 month';

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$$;

grant execute on function public.compute_incentives(uuid, date) to authenticated;
