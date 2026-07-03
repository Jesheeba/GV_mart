-- Phase 5 (ADM-05..08): Sales & invoicing — RPCs.
--
-- `create_sale` is SECURITY DEFINER, unlike `create_customer_with_details`
-- (Phase 3, SECURITY INVOKER). Reason: a product sale's Installation toggle
-- must write `service_tickets`/`appointments`/`inventory_movements` and
-- (when unassigned) `notifications` — all of which are `is_ops_staff()`-only
-- under RLS (Phase 1) — but the caller here is sales_admin/master
-- (`invoices_write_sales` is sales-only). A sales_admin completing a normal
-- product sale would otherwise be blocked by RLS on tables it has no
-- business writing to directly. DEFINER bypasses RLS for the duration of
-- the call, so every authorization check that RLS would have done is
-- re-implemented explicitly at the top instead (role + org-ownership
-- checks) — see the `is_sales_staff()`/`current_org_id()` checks below.
-- `create_quotation` has no such gap (quotations are sales-only end to end)
-- so it stays SECURITY INVOKER, same as the Phase 3 RPC.

-- Internal helper — not granted to `authenticated` directly, only called
-- from within `create_sale`'s DEFINER context. Prices are always looked up
-- fresh from `products`/`spares` here, never trusted from the client cart;
-- the only client-controlled money input is `p_discount_percent`, which
-- `create_sale` caps before this is ever called.
create or replace function public._sale_create_line_invoice(
  p_org_id uuid,
  p_customer_id uuid,
  p_type invoice_type, -- 'product' or 'spare' only
  p_items jsonb, -- [{item_id, qty}, ...]
  p_discount_percent numeric,
  p_gst_rate numeric,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text
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
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
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

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status
  ) values (
    p_org_id, p_customer_id, p_type, v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, p_txn_id, p_payment_description, 'paid'
  ) returning * into v_invoice;

  -- Pass 2: same prices, now writing invoice_items and decrementing stock.
  for v_item in select * from jsonb_to_recordset(p_items) as x(item_id uuid, qty integer)
  loop
    if p_type = 'product' then
      select price into v_price from public.products where id = v_item.item_id and org_id = p_org_id;
    else
      select price into v_price from public.spares where id = v_item.item_id and org_id = p_org_id;
    end if;

    v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

    insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount)
    values (p_org_id, v_invoice.id, v_item_type, v_item.item_id, v_item.qty, v_price, v_line_discount);

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

-- p_cart shape:
-- {
--   spare_items: [{item_id, qty}],
--   product_items: [{item_id, qty, warranty, warranty_months, installation}],
--   amc: {product_id, plan_id} | null,
--   discount_percent, gift_id, payment_method, txn_id, payment_description
-- }
-- p_quotation_id: when converting a quotation, marks it 'converted' in the
-- same transaction as the sale it produced.
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

    insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
    values (
      p_org_id, p_customer_id, v_amc_product_id, v_amc_plan_id, current_date,
      current_date + (v_amc_plan.years || ' years')::interval, 'active',
      current_date + make_interval(months => greatest(1, 12 / v_amc_plan.visits_per_year)),
      v_amc_invoice.id
    );

    -- A plan's own included gift (e.g. a tier that bundles a water bottle)
    -- is distinct from the general above-threshold gift offer below.
    if v_amc_plan.gift_id is not null then
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_amc_invoice.id, v_amc_plan.gift_id);
    end if;
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

-- New Quotation (ADM-08): "sale flow minus payment" — item selection only,
-- no inventory/warranty/installation side-effects, so this stays SECURITY
-- INVOKER (quotations_write_sales / quotation_items_write_sales already
-- allow sales_admin directly, unlike the ops-only tables create_sale needs).
-- AMC items are out of scope here — quotation_items.item_type only covers
-- product/spare (Phase 1 schema); quoting an AMC plan can be added later if
-- the business asks for it.
create or replace function public.create_quotation(
  p_org_id uuid,
  p_customer_id uuid,
  p_valid_until date,
  p_items jsonb -- [{item_type: 'product'|'spare', item_id, qty}]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_quotation_id uuid;
  v_total numeric(12, 2) := 0;
  v_item record;
  v_price numeric(12, 2);
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'create_quotation: at least one item is required';
  end if;

  insert into public.quotations (org_id, customer_id, status, valid_until, total)
  values (p_org_id, p_customer_id, 'open', p_valid_until, 0)
  returning id into v_quotation_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(item_type item_type, item_id uuid, qty integer)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      raise exception 'create_quotation: qty must be positive for item %', v_item.item_id;
    end if;

    if v_item.item_type = 'product' then
      select price into v_price from public.products where id = v_item.item_id and org_id = p_org_id;
    else
      select price into v_price from public.spares where id = v_item.item_id and org_id = p_org_id;
    end if;
    if v_price is null then
      raise exception 'create_quotation: item % not found in org %', v_item.item_id, p_org_id;
    end if;

    insert into public.quotation_items (org_id, quotation_id, item_type, item_id, qty, price)
    values (p_org_id, v_quotation_id, v_item.item_type, v_item.item_id, v_item.qty, v_price);

    v_total := v_total + (v_price * v_item.qty);
  end loop;

  update public.quotations set total = v_total where id = v_quotation_id;

  return v_quotation_id;
end;
$$;

grant execute on function public.create_quotation(uuid, uuid, date, jsonb) to authenticated;
