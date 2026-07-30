-- Task 3 (Customer Dashboard enhancement spec, 2026-07-30): address
-- management everywhere an address is needed (Service Booking already had
-- it via book_service_ticket's p_address_id). This migration:
--   1. Adds a guarded delete_my_address() RPC — the client previously did a
--      raw `.from("addresses").delete()`, relying only on RLS (ownership),
--      with no check that the address isn't linked to an active booking.
--   2. Lets AMC renewal accept an optional customer-picked address instead
--      of always hardcoding the primary address server-side.
--   3. Lets spare/product enquiries optionally carry a selected address —
--      leads had no address concept at all.

-- ── 1. Guarded address delete ────────────────────────────────────────────
create or replace function public.delete_my_address(p_address_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_address addresses;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'delete_my_address: caller is not a customer';
  end if;

  select * into v_address from public.addresses where id = p_address_id and customer_id = v_customer_id;
  if v_address.id is null then
    raise exception 'delete_my_address: address not found';
  end if;

  if v_address.is_primary then
    raise exception 'delete_my_address: set another address as default before deleting this one';
  end if;

  if exists (
    select 1 from public.service_tickets
    where address_id = p_address_id and status not in ('completed', 'cancelled')
  ) then
    raise exception 'delete_my_address: this address is linked to an active booking and cannot be deleted';
  end if;

  delete from public.addresses where id = p_address_id;
end;
$$;

grant execute on function public.delete_my_address(uuid) to authenticated;

-- ── 2. AMC renewal: optional customer-picked address ─────────────────────
-- Adding a new trailing optional parameter to an existing function is a
-- compatible signature change (see 20260724100000's own note on this same
-- function) — every existing caller that omits it keeps today's
-- primary-address behavior.
create or replace function public.renew_amc_plan(
  p_org_id uuid,
  p_product_id uuid,
  p_plan_id uuid,
  p_payment_reference text,
  p_years integer default null,
  p_referred_by_technician_name text default null,
  p_address_id uuid default null
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
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
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

  -- FINDER CREDIT: resolve the optional customer-entered technician name to
  -- a real technicians.id, exact match (case/whitespace-insensitive) against
  -- this org's active technicians only. Zero or 2+ matches (typo, common
  -- name shared by two technicians) silently proceed with no attribution
  -- rather than blocking a paying customer's AMC purchase over a name
  -- lookup — the sale itself must never fail because of this.
  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    select count(*), min(t.id) into v_tech_match_count, v_tech_id
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count <> 1 then
      v_tech_id := null;
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

  v_start_date := greatest(current_date, coalesce(v_existing.expiry_date, current_date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, 12 / v_plan.visits_per_year);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  -- Task 3: use the customer-picked address when given and it's genuinely
  -- theirs; otherwise fall back to today's primary-address lookup so every
  -- pre-existing caller (customer app before this change, technician onsite
  -- sale) behaves exactly as before.
  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => v_interval_months * i);
    exit when v_visit_date > v_expiry;

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

grant execute on function public.renew_amc_plan(uuid, uuid, uuid, text, integer, text, uuid) to authenticated;

-- ── 3. Spare/product enquiry: optional selected address ──────────────────
alter table public.leads add column if not exists address_id uuid references public.addresses (id) on delete set null;
create index if not exists leads_address_id_idx on public.leads (address_id);

create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_lead_id uuid;
  v_note text;
  v_address_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'submit_customer_enquiry: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_customer_enquiry: org mismatch';
  end if;
  if p_kind not in ('product', 'spare') then
    raise exception 'submit_customer_enquiry: invalid kind %', p_kind;
  end if;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

  if v_lead_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status, address_id)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new', v_address_id
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;
  end if;

  v_note := coalesce(nullif(btrim(p_description), ''), '(no description)');
  if p_photo_url is not null and btrim(p_photo_url) <> '' then
    v_note := v_note || format(' [photo: %s]', p_photo_url);
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, p_kind || '_enquiry', v_note);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'sales_admin', 'enquiry_lead',
    case when p_kind = 'product' then 'New product enquiry' else 'New spare enquiry' end,
    v_note, v_lead_id
  );

  return v_lead_id;
end;
$$;

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid) to authenticated;
