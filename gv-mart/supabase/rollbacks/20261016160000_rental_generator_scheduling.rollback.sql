-- Rollback for 20261016160000_rental_generator_scheduling.sql (restores the live bodies as of 20261016120000).
create or replace function public.create_rental(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_address_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_payment_method payment_method DEFAULT 'cash'::payment_method, p_txn_id text DEFAULT NULL::text, p_payment_description text DEFAULT NULL::text)
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

  -- Physical unit leaves warehouse stock â€” same guarded decrement create_sale
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

  -- Month 1 only, billed now â€” month 2 onward is created by the daily
  -- run_rental_billing cron advancing next_billing_date.
  v_gst := round(v_plan.monthly_rate * v_settings.gst_rate / 100, 2);
  v_total := v_plan.monthly_rate + v_gst;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'rent', v_plan.monthly_rate, 0, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''), 'paid', v_total, auth.uid()
  ) returning * into v_invoice;

  insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
  values (p_org_id, 'product', p_product_id, -1, 'rental_out', v_invoice.id);

  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_visit_date := p_start_date + make_interval(months => v_interval_months);

  insert into public.rental_contracts (
    org_id, customer_id, product_id, plan_id, address_id, start_date, status,
    next_billing_date, next_service_date, invoice_id
  ) values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, p_address_id, p_start_date, 'active',
    p_start_date + interval '1 month', v_visit_date, v_invoice.id
  ) returning id into v_contract_id;

  -- Installation, same as create_sale's product-installation branch â€” a
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

  -- First scheduled visit only â€” see create_service_invoice's completion
  -- hook (20260915150000) for how each subsequent one gets created.
  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
    type, priority, status, channel, rental_contract_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, 'Rental scheduled service', v_plan.name,
    'rental', 'normal', 'open', 'walk_in', v_contract_id
  ) returning id into v_visit_ticket_id;

  insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
  values (p_org_id, v_visit_ticket_id, 'datetime', (v_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

  perform public._auto_assign_ticket_internal(v_visit_ticket_id, p_org_id, p_skip_rating_logic => true);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'rental_started', 'Equipment rented out',
    format('%s rental started â€” first service visit scheduled.', v_plan.name), v_contract_id
  );

  return jsonb_build_object(
    'contract_id', v_contract_id,
    'invoice_id', v_invoice.id,
    'install_ticket_id', v_install_ticket_id,
    'visit_ticket_id', v_visit_ticket_id
  );
end;
$function$;
create or replace function public.create_service_invoice(p_org_id uuid, p_visit_id uuid, p_service_charge numeric, p_discount_percent numeric, p_spares jsonb, p_payment_method payment_method, p_txn_id text, p_payment_description text, p_is_chargeable boolean, p_amount_paid numeric DEFAULT NULL::numeric, p_installations jsonb DEFAULT '[]'::jsonb)
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
      v_rental_interval_months := greatest(1, 12 / v_rental_plan.visits_per_year);
      v_rental_visit_date := (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_rental_interval_months);
      v_rental_address_id := coalesce(v_rental_contract.address_id, v_ticket.address_id);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, rental_contract_id
      ) values (
        p_org_id, v_rental_contract.customer_id, v_rental_address_id, v_rental_contract.product_id,
        'Rental scheduled service', v_rental_plan.name, 'rental', 'normal', 'open', 'walk_in', v_rental_contract.id
      )
      returning id into v_rental_ticket_id;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
      values (p_org_id, v_rental_ticket_id, 'datetime', (v_rental_visit_date + time '09:00') at time zone 'Asia/Kolkata', 'scheduled');

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
$function$;
notify pgrst, 'reload schema';
