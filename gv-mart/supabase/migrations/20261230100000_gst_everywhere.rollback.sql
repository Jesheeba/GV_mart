-- Rollback for 20261230100000_gst_everywhere: restores the 8 live definitions read 2026-11-26.
-- Invoices already created by the new code are left as they are.
drop function public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text, payment_method, text, text, boolean);
drop function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, payment_method, text, text, boolean);
drop function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb, boolean);
drop function public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text, numeric, boolean);
drop function public.create_rental(uuid, uuid, uuid, uuid, uuid, date, payment_method, text, text, boolean);

CREATE OR REPLACE FUNCTION public.create_service_invoice(p_org_id uuid, p_visit_id uuid, p_service_charge numeric, p_discount_percent numeric, p_spares jsonb, p_payment_method payment_method, p_txn_id text, p_payment_description text, p_is_chargeable boolean, p_amount_paid numeric DEFAULT NULL::numeric, p_installations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_movement_reason text;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
  v_rental_contract rental_contracts;
  v_rental_plan rental_plans;
  v_rental_interval_months integer;
  v_rental_visit_date date;
  v_rental_ticket_id uuid;
  v_rental_address_id uuid;
  v_install record; -- INSTALLATION TRACKING
  v_credit_qty integer;
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

  -- A completed ticket is never invoiced (or credited) twice. The same technician repeating the call (offline-queue replay)
  -- gets the existing invoice back and nothing else is written; anyone else gets an error.
  if v_ticket.status = 'completed' then
    if v_ticket.invoice_id is not null and v_visit.technician_id = v_tech_id then
      return jsonb_build_object('invoice_id', v_ticket.invoice_id,
        'total', (select i.total from public.invoices i where i.id = v_ticket.invoice_id),
        'approval_id', null, 'already_completed', true);
    end if;
    raise exception 'create_service_invoice: ticket % is already completed', v_ticket.id;
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
  v_gst := public._gst_amount(v_subtotal - v_discount, v_settings.gst_rate, v_settings.prices_include_gst);
  v_total := v_subtotal - v_discount + case when v_settings.prices_include_gst then 0 else v_gst end;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total, gst_inclusive,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total, v_settings.prices_include_gst,
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

      -- This technician's own van balance first (was the pooled, org-wide
      -- `inventory` location='van' row - see this migration's header).
      update public.technician_stock_levels
        set stock_qty = stock_qty - v_item.qty, updated_at = now()
        where org_id = p_org_id and technician_id = v_tech_id
          and item_type = 'spare' and item_id = v_item.spare_id and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;

      if v_new_stock is not null then
        v_movement_reason := 'service_use_van';
      else
        -- Van didn't cover it (never handed over, or not enough) - fall
        -- back to warehouse, same conditional UPDATE as before, but now
        -- tagged so Group 5 reporting can flag the shortfall distinctly
        -- from a normal van deduction.
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
        v_movement_reason := 'service_use_shortfall';
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, v_movement_reason, p_visit_id, v_tech_id);

      -- NEW (requirement 6): a shortfall must be flagged for staff, not just tagged in the
      -- ledger. role='operation_admin' reaches master too via notifications_select_own_role's
      -- is_master() widening -- sales_admin, correctly, does not see it.
      if v_movement_reason = 'service_use_shortfall' then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        select p_org_id, 'operation_admin', 'spare_use_shortfall', 'Spare used with no recorded van stock',
          format('%s used %s x %s on a job without enough recorded van stock; drawn from the warehouse instead. Consider a hand-over.',
            coalesce(p.full_name, 'A technician'), v_item.qty, coalesce(s.name, 'a spare')),
          p_visit_id
        from public.technicians t
        join public.profiles p on p.id = t.profile_id
        left join public.spares s on s.id = v_item.spare_id
        where t.id = v_tech_id;
      end if;
    end loop;
  end if;

  -- INSTALLATION TRACKING: distinct from spares - logs which products were
  -- newly installed on this visit, purely for incentive counting (no
  -- invoice line, no stock movement - the product itself was already sold/
  -- stocked through its own path; this just credits the technician).
  if p_installations is not null and jsonb_array_length(p_installations) > 0 then
    for v_install in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
    loop
      if v_install.qty is null or v_install.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for installed product %', v_install.product_id;
      end if;
      if not exists (select 1 from public.products where id = v_install.product_id and org_id = p_org_id) then
        raise exception 'create_service_invoice: product % not found in org %', v_install.product_id, p_org_id;
      end if;

      insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty)
      values (p_org_id, p_visit_id, v_tech_id, v_install.product_id, v_install.qty);
    end loop;
  end if;

  -- Installation incentive: the ticket's per-unit charge (a master-editable snapshot) x units logged for the ticket's
  -- product, minimum 1. Created PENDING; the master approves it before Compute counts it. One credit per ticket+technician.
  if v_ticket.type = 'installation' and v_ticket.product_id is not null and coalesce(v_ticket.installation_charge_snapshot, 0) > 0 then
    select greatest(1, coalesce(sum(il.qty), 0))::integer into v_credit_qty
    from public.installations_logged il
    where il.visit_id = p_visit_id and il.product_id = v_ticket.product_id;
    insert into public.installation_incentive_credits (org_id, ticket_id, visit_id, technician_id, product_id, qty, unit_amount, amount, status)
    values (p_org_id, v_ticket.id, p_visit_id, v_tech_id, v_ticket.product_id, v_credit_qty,
            v_ticket.installation_charge_snapshot, v_ticket.installation_charge_snapshot * v_credit_qty, 'pending')
    on conflict (ticket_id, technician_id) do nothing;
    if found then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (p_org_id, 'master', 'installation_credit_pending', 'Installation incentive to approve',
              format('Installation completed: incentive of %s (%s unit(s)) is waiting for your approval.',
                     v_ticket.installation_charge_snapshot * v_credit_qty, v_credit_qty), v_ticket.id);
    end if;
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
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if v_ticket.type = 'warranty' and v_ticket.warranty_id is not null then
    update public.warranties
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.warranty_id = v_ticket.warranty_id
          and st.type = 'warranty'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.warranty_id;
  end if;

  if v_ticket.type = 'rental' and v_ticket.rental_contract_id is not null then
    select * into v_rental_contract from public.rental_contracts where id = v_ticket.rental_contract_id;
    if v_rental_contract.status = 'active' then
      select * into v_rental_plan from public.rental_plans where id = v_rental_contract.plan_id;
      -- next visit: round(12 / visits_per_year) months from today (was integer division), rolled to a working day
      v_rental_interval_months := greatest(1, public._visit_month_offset(v_rental_plan.visits_per_year, 1));
      v_rental_visit_date := public._visit_working_day(p_org_id, ((now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_rental_interval_months))::date);
      v_rental_address_id := coalesce(v_rental_contract.address_id, v_ticket.address_id);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, rental_contract_id
      ) values (
        p_org_id, v_rental_contract.customer_id, v_rental_address_id, v_rental_contract.product_id,
        'Rental scheduled service', v_rental_plan.name, 'rental', 'normal', 'open', 'walk_in', v_rental_contract.id
      )
      returning id into v_rental_ticket_id;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
      values (p_org_id, v_rental_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_rental_visit_date),
              public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

      perform public._auto_assign_ticket_internal(v_rental_ticket_id, p_org_id, p_skip_rating_logic => true);

      update public.rental_contracts set next_service_date = v_rental_visit_date where id = v_rental_contract.id;
    end if;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if (now() at time zone 'Asia/Kolkata')::time >= v_settings.work_end then
    update public.attendance
    set shift_end_prompt_pending = true
    where technician_id = v_tech_id and org_id = p_org_id
      and date = (now() at time zone 'Asia/Kolkata')::date;

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select p_org_id, p.id, 'shift_end_prompt', 'Shift end reached',
      format('Your shift ended at %s. Reply to continue or check out.', to_char(v_settings.work_end, 'HH12:MI AM')), v_invoice.id
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  else
    perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sell_amc_plan_onsite(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_method payment_method, p_txn_id text DEFAULT NULL::text, p_payment_description text DEFAULT NULL::text, p_amount_paid numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_gst := public._gst_amount(v_effective_price, v_settings.gst_rate, v_settings.prices_include_gst);
  v_total := v_effective_price + case when v_settings.prices_include_gst then 0 else v_gst end;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'sell_amc_plan_onsite: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'sell_amc_plan_onsite: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total, gst_inclusive,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'amc', v_effective_price, v_discount, v_gst, v_total, v_settings.prices_include_gst,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid, auth.uid()
  ) returning * into v_invoice;

  v_expiry := (now() at time zone 'Asia/Kolkata')::date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
  values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, (now() at time zone 'Asia/Kolkata')::date,
    v_expiry, 'active', (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_interval_months), v_invoice.id
  )
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_invoice.id, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, p_customer_id, v_contract_id, p_product_id, v_plan.name,
    v_plan.visits_per_year, v_total_visits, (now() at time zone 'Asia/Kolkata')::date, v_expiry, v_address_id, v_lead_id, 'field');

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
$function$
;

CREATE OR REPLACE FUNCTION public.create_rental(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_address_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_payment_method payment_method DEFAULT 'cash'::payment_method, p_txn_id text DEFAULT NULL::text, p_payment_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_plan rental_plans;
  v_settings settings;
  v_contract_id uuid;
  v_invoice invoices;
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_new_stock integer;
  v_interval_months integer;
  v_visit_date date;
  v_visit_ticket_id uuid;
  v_install_ticket_id uuid;
begin
  if not (public.is_ops_staff() or public.is_sales_staff()) then
    raise exception 'create_rental: only master, operation_admin, or sales_admin may rent out equipment';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_rental: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_rental: customer % not found', p_customer_id;
  end if;
  if not exists (select 1 from public.addresses where id = p_address_id and customer_id = p_customer_id) then
    raise exception 'create_rental: address % does not belong to customer %', p_address_id, p_customer_id;
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id) then
    raise exception 'create_rental: product % not found', p_product_id;
  end if;

  select * into v_plan from public.rental_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'create_rental: rental plan % not found', p_plan_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_rental: no settings row for org %', p_org_id;
  end if;

  if p_payment_method = 'transfer' and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_rental: bank transfer requires a transaction ID and description';
  end if;

  -- Physical unit leaves warehouse stock - same guarded decrement create_sale
  -- uses for a product sale. Rented units aren't tracked in a separate
  -- location bucket (see the schema migration's own note): the
  -- rental_contracts row IS the record of "which unit is out and to whom".
  update public.inventory
    set stock_qty = stock_qty - 1
    where org_id = p_org_id and item_type = 'product' and item_id = p_product_id
      and location = 'warehouse' and stock_qty >= 1
    returning stock_qty into v_new_stock;
  if v_new_stock is null then
    raise exception 'create_rental: no warehouse stock available for this product';
  end if;

  -- Month 1 only, billed now - month 2 onward is created by the daily
  -- run_rental_billing cron advancing next_billing_date.
  v_gst := public._gst_amount(v_plan.monthly_rate, v_settings.gst_rate, v_settings.prices_include_gst);
  v_total := v_plan.monthly_rate + case when v_settings.prices_include_gst then 0 else v_gst end;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total, gst_inclusive,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'rent', v_plan.monthly_rate, 0, v_gst, v_total, v_settings.prices_include_gst,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''), 'paid', v_total, auth.uid()
  ) returning * into v_invoice;

  insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
  values (p_org_id, 'product', p_product_id, -1, 'rental_out', v_invoice.id);

  -- first service visit: round(12 / visits_per_year) months out (was integer division), rolled to a working day
  v_interval_months := greatest(1, public._visit_month_offset(v_plan.visits_per_year, 1));
  v_visit_date := public._visit_working_day(p_org_id, (p_start_date + make_interval(months => v_interval_months))::date);

  insert into public.rental_contracts (
    org_id, customer_id, product_id, plan_id, address_id, start_date, status,
    next_billing_date, next_service_date, invoice_id
  ) values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, p_address_id, p_start_date, 'active',
    p_start_date + interval '1 month', v_visit_date, v_invoice.id
  ) returning id into v_contract_id;

  -- Installation, same as create_sale's product-installation branch - a
  -- rented unit needs delivery/setup exactly like a purchased one.
  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
    type, priority, status, channel, invoice_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, 'Installation', 'New rental installation',
    'installation', 'normal', 'open', 'walk_in', v_invoice.id
  ) returning id into v_install_ticket_id;
  insert into public.appointments (org_id, ticket_id, mode, status)
  values (p_org_id, v_install_ticket_id, 'always', 'scheduled');
  perform public._auto_assign_ticket_internal(v_install_ticket_id, p_org_id, p_skip_rating_logic => true);

  -- First scheduled visit only - see create_service_invoice's completion
  -- hook (20260915150000) for how each subsequent one gets created.
  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
    type, priority, status, channel, rental_contract_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, 'Rental scheduled service', v_plan.name,
    'rental', 'normal', 'open', 'walk_in', v_contract_id
  ) returning id into v_visit_ticket_id;

  -- starts at the master's working-hours start (settings.work_start) and carries the working window, not a hard-coded 09:00
  insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
  values (p_org_id, v_visit_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date),
          public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

  perform public._auto_assign_ticket_internal(v_visit_ticket_id, p_org_id, p_skip_rating_logic => true);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'rental_started', 'Equipment rented out',
    format('%s rental started - first service visit scheduled.', v_plan.name), v_contract_id
  );

  return jsonb_build_object(
    'contract_id', v_contract_id,
    'invoice_id', v_invoice.id,
    'install_ticket_id', v_install_ticket_id,
    'visit_ticket_id', v_visit_ticket_id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.run_rental_billing(p_org_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_contract record;
  v_settings settings;
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_count integer := 0;
begin
  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    return 0;
  end if;

  for v_contract in
    select rc.*, rp.monthly_rate, rp.name as plan_name
    from public.rental_contracts rc
    join public.rental_plans rp on rp.id = rc.plan_id
    where rc.org_id = p_org_id and rc.status = 'active' and rc.next_billing_date <= (now() at time zone 'Asia/Kolkata')::date
  loop
    v_gst := public._gst_amount(v_contract.monthly_rate, v_settings.gst_rate, v_settings.prices_include_gst);
    v_total := v_contract.monthly_rate + case when v_settings.prices_include_gst then 0 else v_gst end;

    insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, gst_inclusive, payment_method, payment_status, amount_paid)
    values (p_org_id, v_contract.customer_id, 'rent', v_contract.monthly_rate, 0, v_gst, v_total, v_settings.prices_include_gst, null, 'due', 0);

    update public.rental_contracts
      set next_billing_date = next_billing_date + interval '1 month'
      where id = v_contract.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sell_amc_plan(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_years integer DEFAULT NULL::integer, p_referred_by_technician_id uuid DEFAULT NULL::uuid, p_confirm_backdated boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_lead_id uuid; -- REFERRAL (new): resolved technician referral, if any
  v_customer_name text;
  v_days_back integer;
  v_max_back integer;
  v_confirmed uuid;
  v_skipped integer[];
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

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'sell_amc_plan: years must be greater than zero';
  end if;

  -- back-dated start: refused beyond the threshold unless a master confirms it explicitly
  select coalesce(s.amc_backdate_max_days, 7) into v_max_back from public.settings s where s.org_id = p_org_id;
  v_max_back := coalesce(v_max_back, 7);
  v_days_back := (now() at time zone 'Asia/Kolkata')::date - p_start_date;
  if v_days_back > v_max_back then
    if not (coalesce(p_confirm_backdated, false) and public.is_master()) then
      raise exception 'AMC_BACKDATED: start date % is % days in the past (limit % days). A master must confirm a back-dated sale.',
        p_start_date, v_days_back, v_max_back using errcode = 'P0001';
    end if;
    v_confirmed := auth.uid();
  end if;

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'AMC sale, referred by technician');
  end if;

  v_expiry := p_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, backdated_confirmed_by)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months), v_confirmed)
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  -- The helper creates the visits (visit 1 on the start date, then every 12 / visits-per-year months) and assigns the ones
  -- inside settings.amc_assign_window_days now; later ones are assigned by assign_due_amc_visits() when they fall due.
  v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, p_customer_id, v_contract_id, p_product_id, v_plan.name,
    v_plan.visits_per_year, v_total_visits, p_start_date, v_expiry, v_address_id, v_lead_id, 'call');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  select c.visits_skipped into v_skipped from public.amc_contracts c where c.id = v_contract_id;
  return jsonb_build_object(
    'contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry,
    'visits_expected', v_total_visits,
    'visits_created', coalesce(array_length(v_ticket_ids, 1), 0),
    -- the skipped visits, named: number and the date each would have been on
    'visits_skipped', coalesce((
      select jsonb_agg(jsonb_build_object('visit_no', k, 'would_have_been_on', public._amc_visit_date(p_start_date, v_plan.visits_per_year, k)) order by k)
        from unnest(v_skipped) as k), '[]'::jsonb),
    'backdated_confirmed', v_confirmed is not null);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.renew_amc_plan(p_org_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_reference text, p_years integer DEFAULT NULL::integer, p_referred_by_technician_name text DEFAULT NULL::text, p_address_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
  v_referral_matched boolean; -- F-05: null = no name given; true/false = matched or not
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

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    -- Pre-existing live bug, found and fixed while adding the referral_matched
    -- signal below (same lines, same migration): the old `min(t.id)` aggregate
    -- raises "function min(uuid) does not exist" on this Postgres version --
    -- uuid has no min/max aggregate defined. This meant ANY renewal where a
    -- customer typed ANY referring-technician name (match or no match) crashed
    -- the entire renew_amc_plan call with an unhandled error, not just the
    -- referral attribution -- confirmed live in this migration's own rehearsal
    -- (first run failed with exactly that error on real test data). Replaced
    -- with a plain count, then a separate id lookup only when the count is
    -- exactly 1 -- same matching semantics, no aggregate-on-uuid involved.
    select count(*) into v_tech_match_count
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count = 1 then
      select t.id into v_tech_id
      from public.technicians t
      join public.profiles pr on pr.id = t.profile_id
      where t.org_id = p_org_id
        and t.is_active = true
        and pr.is_active = true
        and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name))
      limit 1;
      v_referral_matched := true;
    else
      v_tech_id := null;
      v_referral_matched := false;
    end if;
  end if;

  if v_tech_id is not null then
    select name into v_customer_name from public.customers where id = v_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', v_tech_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', format('AMC self-service purchase, referred by %s', p_referred_by_technician_name));
  end if;

  v_start_date := greatest((now() at time zone 'Asia/Kolkata')::date, coalesce(v_existing.expiry_date, (now() at time zone 'Asia/Kolkata')::date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => public._visit_month_offset(v_plan.visits_per_year, i));
    exit when v_visit_date > v_expiry;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'customer_app', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) â€” payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry, 'referral_matched', v_referral_matched);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sell_amc_plan_with_referrer(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_years integer DEFAULT NULL::integer, p_referred_by_technician_id uuid DEFAULT NULL::uuid, p_confirm_backdated boolean DEFAULT false, p_referred_by_user_id uuid DEFAULT NULL::uuid, p_referred_by_customer_id uuid DEFAULT NULL::uuid, p_referred_by_name text DEFAULT NULL::text, p_referred_by_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_referred_by_technician_id is not null
     and num_nonnulls(p_referred_by_user_id, p_referred_by_customer_id, nullif(btrim(coalesce(p_referred_by_name, '')), '')) > 0 then
    raise exception 'referrer: pick only one referrer';
  end if;
  perform public._record_transaction_referrer(p_org_id, p_customer_id, p_referred_by_user_id, p_referred_by_customer_id, p_referred_by_name, p_referred_by_phone, 'AMC sale');
  return public.sell_amc_plan(p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, p_years, p_referred_by_technician_id, p_confirm_backdated);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_customer_app_settings(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select to_jsonb(t) from (
    select
      amc_book_window_days,
      review_link_min_stars,
      google_review_url,
      emi_enabled,
      emi_tenure_months,
      emi_disclaimer,
      work_start,
      work_end,
      narrow_window_threshold_minutes,
      default_duration_paid_minutes
    from public.settings
    where org_id = p_org_id
      and org_id = public.current_org_id()
  ) t
$function$
;

revoke all on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) from public, anon;
grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) to authenticated, service_role;
revoke all on function public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text, numeric) from public, anon;
grant execute on function public.sell_amc_plan_onsite(uuid, uuid, uuid, uuid, payment_method, text, text, numeric) to authenticated, service_role;
revoke all on function public.create_rental(uuid, uuid, uuid, uuid, uuid, date, payment_method, text, text) from public, anon;
grant execute on function public.create_rental(uuid, uuid, uuid, uuid, uuid, date, payment_method, text, text) to authenticated, service_role;
revoke all on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid, boolean) from public, anon;
grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid, boolean) to authenticated, service_role;
revoke all on function public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text) from public, anon;
grant execute on function public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text) to authenticated, service_role;
alter table public.rental_contracts drop column if exists gst_inclusive;
