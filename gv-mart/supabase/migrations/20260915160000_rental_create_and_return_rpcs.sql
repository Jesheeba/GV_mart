-- Item D5: "Rent Out" and "Mark Returned" — the two staff-facing actions.
-- create_rental mirrors sell_amc_plan_onsite's shape (invoice + contract +
-- first scheduled visit + installation ticket), plus the physical-inventory
-- decrement a sale would do (an AMC add-on has nothing to decrement; a
-- rented unit does — it's leaving the shelf). mark_rental_returned is the
-- inverse: stock back, contract closed, no more visits.

create or replace function public.create_rental(
  p_org_id uuid,
  p_customer_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_address_id uuid,
  p_start_date date default current_date,
  p_payment_method payment_method default 'cash',
  p_txn_id text default null,
  p_payment_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Physical unit leaves warehouse stock — same guarded decrement create_sale
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

  -- Month 1 only, billed now — month 2 onward is created by the daily
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

  -- Installation, same as create_sale's product-installation branch — a
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

  -- First scheduled visit only — see create_service_invoice's completion
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
    format('%s rental started — first service visit scheduled.', v_plan.name), v_contract_id
  );

  return jsonb_build_object(
    'contract_id', v_contract_id,
    'invoice_id', v_invoice.id,
    'install_ticket_id', v_install_ticket_id,
    'visit_ticket_id', v_visit_ticket_id
  );
end;
$$;

grant execute on function public.create_rental(uuid, uuid, uuid, uuid, uuid, date, payment_method, text, text) to authenticated;

create or replace function public.mark_rental_returned(p_org_id uuid, p_contract_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contract rental_contracts;
begin
  if not (public.is_ops_staff() or public.is_sales_staff()) then
    raise exception 'mark_rental_returned: only master, operation_admin, or sales_admin may process a return';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'mark_rental_returned: org mismatch';
  end if;

  select * into v_contract from public.rental_contracts where id = p_contract_id and org_id = p_org_id;
  if v_contract.id is null then
    raise exception 'mark_rental_returned: contract % not found', p_contract_id;
  end if;
  if v_contract.status = 'returned' then
    raise exception 'mark_rental_returned: contract % was already returned', p_contract_id;
  end if;

  update public.rental_contracts
    set status = 'returned', returned_at = now(), next_billing_date = null
    where id = p_contract_id;

  -- No more technician visits once the unit is back with GV Mart.
  update public.appointments a
    set status = 'cancelled'
    from public.service_tickets st
    where a.ticket_id = st.id and st.rental_contract_id = p_contract_id and a.status in ('scheduled', 'in_progress');
  update public.service_tickets
    set status = 'cancelled', cancellation_reason = 'Rental returned', cancelled_at = now()
    where rental_contract_id = p_contract_id and status in ('open', 'assigned', 'in_progress');

  update public.inventory
    set stock_qty = stock_qty + 1
    where org_id = p_org_id and item_type = 'product' and item_id = v_contract.product_id and location = 'warehouse';

  insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
  values (p_org_id, 'product', v_contract.product_id, 1, 'rental_return', p_contract_id);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'rental_returned', 'Rental equipment returned', 'Equipment has been picked up and returned to stock.', p_contract_id);
end;
$$;

grant execute on function public.mark_rental_returned(uuid, uuid) to authenticated;

-- ── Daily billing cron RPC — service_role only (no grant to authenticated,
-- same pattern as open_monthly_quote_requests/wa_resolve_purchase_quote_
-- requests), called from wa-scheduled-tasks. Advances next_billing_date
-- itself, so it's safe to call repeatedly — a contract not yet due is a
-- no-op. ─────────────────────────────────────────────────────────────────
create or replace function public.run_rental_billing(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
    where rc.org_id = p_org_id and rc.status = 'active' and rc.next_billing_date <= current_date
  loop
    v_gst := round(v_contract.monthly_rate * v_settings.gst_rate / 100, 2);
    v_total := v_contract.monthly_rate + v_gst;

    insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_method, payment_status, amount_paid)
    values (p_org_id, v_contract.customer_id, 'rent', v_contract.monthly_rate, 0, v_gst, v_total, null, 'due', 0);

    update public.rental_contracts
      set next_billing_date = next_billing_date + interval '1 month'
      where id = v_contract.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
