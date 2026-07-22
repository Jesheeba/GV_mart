-- Build-audit fixes, AMC domain:
--
-- Fix 1: amc_plans priced by a fixed price+years pair only — no way to sell
-- "the same plan, a different number of years" with a computed price.
-- Adds amc_plans.price_per_year (nullable, backfilled from the existing
-- price/years so old rows keep working) as the new source of truth for
-- sale-time pricing, and a p_years parameter to sell_amc_plan/renew_amc_plan
-- so a purchase/renewal can choose a duration other than the plan's own
-- default `years`. `price` is kept as-is — it now means "reference total
-- for the plan's own stated years", still shown in the plan list, but no
-- longer read by any pricing/invoice calculation.
--
-- NOTE on sell_amc_plan/renew_amc_plan: neither function creates an invoice
-- or does any price math today — both were read in full from
-- 20260715215000_assigned_at_sla_and_rating_reassignment.sql (their current
-- live bodies) before this migration was written, and confirmed to only use
-- v_plan.years/visits_per_year/gift_id/name, never v_plan.price. The only
-- RPC that actually prices an AMC sale in dollars-and-cents is create_sale's
-- AMC add-on block, so that is the only function where "price_per_year
-- instead of price" changes an actual invoice total. sell_amc_plan/
-- renew_amc_plan only gain p_years so the contract's expiry date and
-- visit-schedule length follow the chosen duration; the computed total is
-- otherwise purely a client-side display value (SellAmcPanel /
-- CustomerAmcPage), matching how `price` was already only ever a display
-- value for these two entry points.
--
-- Fix 2: create_service_invoice zeroed out EVERY spare on any non-chargeable
-- (amc/warranty) ticket, with no way to say "this spare isn't covered by the
-- plan, bill it anyway". Adds amc_plan_covered_spares (plan_id, spare_id)
-- and changes create_service_invoice's per-spare pricing to check, for
-- AMC-typed tickets with a resolvable plan, whether each spare is on that
-- plan's covered list — uncovered spares bill at normal price even on an
-- otherwise-free AMC visit. Warranty tickets (no amc_plans concept) and AMC
-- tickets with no resolvable plan (legacy contract_id null data) keep the
-- prior "all free" behaviour unchanged, per the fix spec's explicit
-- fallback requirement.

-- ── Fix 1: price_per_year ────────────────────────────────────────────────
alter table public.amc_plans add column if not exists price_per_year numeric(12, 2);

update public.amc_plans
  set price_per_year = round(price / greatest(years, 1), 2)
  where price_per_year is null;

-- ── Fix 2: covered-spares join table ─────────────────────────────────────
create table if not exists public.amc_plan_covered_spares (
  plan_id uuid not null references public.amc_plans (id) on delete cascade,
  spare_id uuid not null references public.spares (id) on delete cascade,
  primary key (plan_id, spare_id)
);

alter table public.amc_plan_covered_spares enable row level security;

-- Mirrors amc_plans' own policies exactly (20260701091300_rls.sql:
-- amc_plans_select_org / amc_plans_write_master) — this table has no
-- org_id column of its own (per spec), so both policies join through
-- amc_plans to reach org_id/current_org_id() instead of comparing directly.
create policy amc_plan_covered_spares_select_org on public.amc_plan_covered_spares
  for select using (
    exists (
      select 1 from public.amc_plans p
      where p.id = plan_id and p.org_id = public.current_org_id()
    )
  );

create policy amc_plan_covered_spares_write_master on public.amc_plan_covered_spares for all
  using (
    exists (
      select 1 from public.amc_plans p
      where p.id = plan_id and p.org_id = public.current_org_id() and public.is_master()
    )
  )
  with check (
    exists (
      select 1 from public.amc_plans p
      where p.id = plan_id and p.org_id = public.current_org_id() and public.is_master()
    )
  );

-- ── sell_amc_plan: verbatim body from 20260715215000 (its current live
-- version — this migration's header note explains why there is no price
-- math to touch here), adding p_years. A new trailing parameter is a
-- DIFFERENT signature to Postgres (same overload-resolution trap documented
-- in 20260715215000 for _auto_assign_ticket_internal), so the old 5-arg
-- overload is dropped first — otherwise existing 5-arg callers (this app's
-- only caller, services/amc.ts's sellAmcPlan) would keep resolving to the
-- old, un-fixed function instead of falling through to this one's default. ──
drop function if exists public.sell_amc_plan(uuid, uuid, uuid, uuid, date);

create or replace function public.sell_amc_plan(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_start_date date default current_date,
  p_years integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan amc_plans;
  v_years integer;
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

  -- Fix 1: a purchase may choose a duration other than the plan's own
  -- default `years` (e.g. buy a "3-year plan" for just 1 year); falls back
  -- to the plan's own years when not passed, for backward compatibility.
  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'sell_amc_plan: years must be greater than zero';
  end if;

  v_expiry := p_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_years * v_plan.visits_per_year;

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

grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer) to authenticated;

-- ── renew_amc_plan: verbatim body from 20260715215000, same p_years addition
-- and same drop-then-create for the same overload-resolution reason. ───────
drop function if exists public.renew_amc_plan(uuid, uuid, uuid, text);

create or replace function public.renew_amc_plan(
  p_org_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_reference text,
  p_years integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_plan amc_plans;
  v_years integer;
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

  -- Fix 1: same "choose your own duration" as sell_amc_plan.
  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
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
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_years * v_plan.visits_per_year;

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
    format('%s plan (%s years) — payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$$;

grant execute on function public.renew_amc_plan(uuid, uuid, uuid, text, integer) to authenticated;

-- NOTE: this migration originally also redefined create_sale here with the
-- AMC price_per_year fix (v_amc_years/v_amc_price_per_year/v_amc_effective_price
-- replacing the flat v_amc_plan.price). Two OTHER migrations applying around
-- the same time (20260716130000_warranty_scheduled_visits.sql and
-- 20260716140000_sales_income_attribution.sql) ALSO independently redefine
-- create_sale, each unaware of the others' changes — three separate
-- `create or replace function create_sale` statements each starting from the
-- same base body would silently clobber each other in push order, with only
-- the LAST one applied actually surviving live. Rather than leave three
-- competing partial definitions, this AMC pricing fix has been merged
-- directly into the one canonical create_sale definition that now lives in
-- 20260716140000_sales_income_attribution.sql (the highest-timestamped of
-- the three, so it applies last and its merged body is what's actually
-- live) — see that file for the AMC add-on block combining sold_by
-- attribution + price_per_year pricing + warranty scheduling +
-- p_skip_rating_logic together. This migration's own create_sale definition
-- was removed to avoid three contradictory copies existing in the migration
-- history.

-- ── create_service_invoice: verbatim body from
-- 20260715110000_amc_multiyear_scheduling_and_next_service_recalc.sql (its
-- current live version, confirmed by grepping every migration for
-- "create or replace function public.create_service_invoice" and reading
-- the highest-timestamped hit — 20260715110000 is the only file after
-- 20260702120000's original definition to redefine it). Signature is
-- unchanged (the covered-spares check is entirely internal, resolved from
-- the ticket's own contract_id — no new parameter needed), so a plain
-- create-or-replace is enough. ─────────────────────────────────────────────
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
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
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
