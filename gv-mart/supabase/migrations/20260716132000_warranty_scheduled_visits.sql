-- Warranty proactive scheduled visits.
--
-- Gap: `warranties` had no `next_service_date` and no scheduling logic at
-- all — a warranty-typed ticket was ONLY ever created reactively, when a
-- customer complains and `_detect_ticket_type()` finds an active warranty
-- (20260702110100_service_amc_functions.sql). Compare `amc_contracts`, which
-- proactively schedules visits in `sell_amc_plan`/`renew_amc_plan`/
-- `create_sale`'s AMC add-on.
--
-- Fix: give warranties a simple FIXED quarterly (every 3 months) visit
-- cadence from start_date to expiry_date — mirroring sell_amc_plan's
-- visit-scheduling loop shape, but deliberately NOT introducing a new
-- admin-configurable "warranty plan" concept (out of scope). Applied at both
-- warranty-creation entry points:
--   1. create_sale's per-product warranty registration (product sale add-on)
--   2. register_product_via_qr (customer self-registration)
-- Both call _auto_assign_ticket_internal(..., p_skip_rating_logic => true)
-- for each scheduled visit, same as AMC visits — these are scheduled
-- maintenance visits, not "standard service ticket" rating-based
-- reassignment scenarios.

alter table public.warranties add column if not exists next_service_date date;

-- NOTE: this migration originally also redefined create_sale here with the
-- warranty quarterly-visit-scheduling block. Two OTHER migrations applying
-- around the same time (20260716130000_amc_price_per_year_and_covered_spares.sql
-- and 20260716140000_sales_income_attribution.sql) ALSO independently
-- redefine create_sale, each unaware of the others' changes. Rather than
-- leave three competing partial definitions where only the last-applied one
-- would actually survive, this warranty-scheduling fix has been merged
-- directly into the one canonical create_sale definition that now lives in
-- 20260716140000_sales_income_attribution.sql (the highest-timestamped of
-- the three, so it applies last) — see that file for the merged per-product
-- warranty branch combining the warranty insert + quarterly scheduling +
-- p_skip_rating_logic together with the other two migrations' fixes. This
-- migration's own create_sale definition was removed to avoid three
-- contradictory copies existing in the migration history. register_product_via_qr
-- below (the OTHER warranty-creation entry point) is unaffected by this and
-- keeps its own quarterly-scheduling block exactly as originally written.
--
-- ── register_product_via_qr: verbatim body from
-- 20260702130100_customer_app_functions.sql, only change is a new
-- quarterly-visit-scheduling block after the existing warranty insert +
-- notification, before the final return. Signature/grant unchanged. ───────
create or replace function public.register_product_via_qr(
  p_org_id uuid,
  p_product_id uuid,
  p_serial_no text,
  p_purchase_date date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_product products;
  v_warranty_id uuid;
  v_warranty warranties;
  v_address_id uuid;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'register_product_via_qr: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'register_product_via_qr: org mismatch';
  end if;

  select * into v_product from public.products where id = p_product_id and org_id = p_org_id;
  if v_product.id is null then
    raise exception 'register_product_via_qr: product % not found', p_product_id;
  end if;

  if p_serial_no is not null and btrim(p_serial_no) <> '' and exists (
    select 1 from public.warranties where org_id = p_org_id and serial_no = p_serial_no
  ) then
    raise exception 'register_product_via_qr: serial number % is already registered', p_serial_no;
  end if;

  insert into public.warranties (org_id, customer_id, product_id, serial_no, start_date, expiry_date)
  values (
    p_org_id, v_customer_id, p_product_id, nullif(btrim(p_serial_no), ''),
    coalesce(p_purchase_date, current_date),
    coalesce(p_purchase_date, current_date) + make_interval(months => v_product.warranty_months)
  )
  returning id into v_warranty_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'product_registered', 'Product registered via QR', v_product.name, v_warranty_id);

  -- Proactive quarterly warranty visits (this migration's gap fix): same
  -- fixed-cadence scheduling as create_sale's per-product warranty
  -- registration above — this is the customer self-registration path for
  -- the same warranties table. p_skip_rating_logic => true, same reasoning.
  select * into v_warranty from public.warranties where id = v_warranty_id;
  select a.id into v_address_id from public.addresses a
  where a.customer_id = v_customer_id and a.is_primary = true limit 1;

  v_total_visits := floor(
    (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
      + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
  )::integer;

  v_visit_date := v_warranty.start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
    exit when v_visit_date > v_warranty.expiry_date;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('Warranty scheduled service %s of %s', i, v_total_visits), 'Warranty scheduled service',
      'warranty', 'normal', 'open', 'customer_app'
    )
    returning id into v_ticket_id;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, 'datetime', v_visit_date::timestamptz + time '09:00', 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);

    if i = 1 then
      update public.warranties set next_service_date = v_visit_date where id = v_warranty_id;
    end if;
  end loop;

  return v_warranty_id;
end;
$$;

grant execute on function public.register_product_via_qr(uuid, uuid, text, date) to authenticated;
