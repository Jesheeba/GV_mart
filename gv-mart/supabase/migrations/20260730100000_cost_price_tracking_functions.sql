-- Cost/margin tracking, stage 1 (functions) — wires the columns added in
-- 20260730090000_cost_price_tracking_schema.sql into the four places cost
-- actually flows: a PO/bill receipt sets an item's cost basis; a sale,
-- a service visit's spare consumption, and a gift handover each snapshot
-- that cost basis onto their own row at the moment they happen.
--
-- Every function below is `create or replace` on top of its confirmed-live
-- body (verified by grepping every migration for the function name and
-- reading the highest-timestamped definition) — nothing here is a parallel
-- copy, only the minimum lines needed for cost tracking are added.

-- ── create_bill_entry: verbatim body from
-- 20260722100000_build_order_step1_fixes.sql (its live version — nothing
-- has redefined it since), plus the cost_price update (owner decision A:
-- "latest price paid", not a running average) inside the existing per-item
-- loop. Runs for whatever item_type the loop is already handling —
-- product/spare/gift, no special-casing needed. ───────────────────────────
create or replace function public.create_bill_entry(
  p_org_id uuid,
  p_supplier_id uuid,
  p_po_id uuid,
  p_items jsonb,
  p_gst numeric,
  p_bill_date date,
  p_bill_image_url text,
  p_category expense_category default 'purchase'
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_item record;
  v_subtotal numeric(12, 2) := 0;
  v_bill_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_bill_entry: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_bill_entry: caller is not ops staff';
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      continue;
    end if;
    v_subtotal := v_subtotal + (v_item.qty * coalesce(v_item.price, 0));

    update public.inventory
      set stock_qty = stock_qty + v_item.qty
      where org_id = p_org_id and item_type = v_item.item_type and item_id = v_item.item_id;

    if not found then
      insert into public.inventory (org_id, item_type, item_id, stock_qty)
      values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty);
    end if;

    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty, 'purchase_receipt', p_po_id);

    -- Cost tracking (stage 1, decision A): the latest price actually paid on
    -- a receipt becomes this item's cost basis going forward. Only updates
    -- when a real price was entered — a null/blank line never zeroes out an
    -- item's existing cost_price.
    if v_item.price is not null then
      if v_item.item_type = 'product' then
        update public.products set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      elsif v_item.item_type = 'spare' then
        update public.spares set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      elsif v_item.item_type = 'gift' then
        update public.gifts set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      end if;
    end if;
  end loop;

  insert into public.purchase_bills (org_id, supplier_id, po_id, amount, gst, bill_image_url)
  values (p_org_id, p_supplier_id, p_po_id, v_subtotal, coalesce(p_gst, 0), p_bill_image_url)
  returning id into v_bill_id;

  insert into public.expenses (org_id, category, amount, ref_id, date)
  values (p_org_id, coalesce(p_category, 'purchase'), v_subtotal + coalesce(p_gst, 0), v_bill_id, coalesce(p_bill_date, current_date));

  if p_po_id is not null then
    update public.purchase_orders set status = 'received' where id = p_po_id and org_id = p_org_id;
  end if;

  return v_bill_id;
end;
$$;

grant execute on function public.create_bill_entry(uuid, uuid, uuid, jsonb, numeric, date, text, expense_category) to authenticated;

-- ── _sale_create_line_invoice: verbatim body from
-- 20260716140000_sales_income_attribution.sql (its live version — comment
-- there confirms it was "never redefined since" as of that migration, and
-- no later migration touches it either), plus a cost snapshot onto each
-- invoice_items row (pass 2, where price is already being re-read from the
-- master). Null when the item has no cost_price set yet — never fabricated.
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

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, sold_by
  ) values (
    p_org_id, p_customer_id, p_type, v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, p_txn_id, p_payment_description, 'paid', auth.uid()
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

-- ── create_service_invoice: verbatim body from
-- 20260716130000_amc_price_per_year_and_covered_spares.sql (its confirmed
-- live version), plus a cost snapshot onto the spare's invoice_items row.
-- Critical subtlety (owner spec item 5): this snapshot reads spares.cost_price
-- BEFORE v_price gets zeroed for a covered AMC/warranty spare a few lines
-- down — so an AMC/warranty visit still records real cost-out even though
-- it charges the customer ₹0. This is deliberately NOT read from
-- service_spares_used.cost — that column is qty × the CHARGED price (₹0 on
-- exactly these free jobs), not acquisition cost; seeded from it would have
-- silently undercounted the cost this fix exists to capture. ─────────────
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
  -- v2.2 §6.1/§6.7: technician up to 5% needs nothing extra, 5-10% needs a
  -- master's approval (below, non-blocking), above the admin max is a hard block.
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  -- Fix 2: resolve the ticket's AMC plan, if any, so the per-spare loops
  -- below can check real coverage instead of zeroing every spare out.
  -- Only AMC-typed tickets have a resolvable plan via contract_id ->
  -- amc_contracts.plan_id — warranty tickets have no amc_plans concept at
  -- all, and legacy AMC tickets with a null contract_id (pre-
  -- 20260713090000 data) have none either, so v_amc_plan_id stays null in
  -- both cases and the coverage check below degrades to the prior
  -- "everything free" behaviour for them, per the fix's explicit fallback
  -- requirement.
  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  -- v2.2 §6.2/§6.3: warranty/AMC visits cost the customer ₹0 (service charge
  -- forced server-side, never trusted from the client toggle).
  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  -- Pass 1: price every spare line from the master (server-side, never the
  -- client) and accumulate the subtotal. Warranty/AMC spares price at 0
  -- UNLESS the spare is not on the ticket's AMC plan's covered list (Fix
  -- 2's hard gate) — an uncovered spare bills at full price even on an
  -- otherwise-free AMC visit. Quantity is always recorded either way.
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

  -- Service charge line (only when actually chargeable and > 0). Modeled as
  -- an invoice_item against nothing tidy in the item_type enum (product |
  -- spare) to represent "labour" — so the charge lives on invoices.subtotal
  -- directly and only spares get line items. This keeps invoice_items
  -- strictly polymorphic over real catalog rows, matching Phase 5.
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

      -- Cost tracking (stage 1, spec item 5): v_cost was read above, before
      -- v_price got zeroed for a covered AMC/warranty spare — so this line
      -- carries the real acquisition cost regardless of what's charged.
      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

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

  -- next_service_date recalculation (20260715110000 bug fix, unchanged).
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

-- ── _gift_log_decrement_stock: verbatim body from
-- 20260729120000_gift_inventory_tracking.sql, plus a cost snapshot onto the
-- gift_logs row it's already firing for. A gift given away is pure cost, no
-- revenue anywhere else — extending the same "free but still costs money"
-- principle as create_service_invoice above, to gifts (flagged as a scope
-- call in the build report: the owner's spec named this explicitly for
-- AMC/warranty spares only, not gifts, but leaving gifts.cost_price
-- collected and never used anywhere would be dead data). Runs via a plain
-- UPDATE rather than setting NEW.cost, since this is an AFTER INSERT
-- trigger — updating the just-inserted row by id is safe here (no
-- recursion: the trigger only fires on INSERT, not UPDATE). ─────────────
create or replace function public._gift_log_decrement_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.gift_logs
    set cost = (select cost_price from public.gifts where id = new.gift_id)
    where id = new.id;

  update public.inventory
    set stock_qty = stock_qty - 1
    where org_id = new.org_id and item_type = 'gift' and item_id = new.gift_id
      and location = 'warehouse' and stock_qty > 0;

  if found then
    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (new.org_id, 'gift', new.gift_id, -1, 'gift_given', new.invoice_id);
  end if;

  return new;
end;
$$;
