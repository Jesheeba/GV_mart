-- Phase 2b Step 2 fix: wa_identify_customer's products union (Phase 1,
-- 20260819120000) listed one row per amc_contracts/warranties record, not
-- one row per product — a product with 3 historical warranty periods, or
-- one with both an AMC contract and a warranty record, showed up multiple
-- times. Surfaced immediately by the Service journey's product-picker list
-- (5 duplicate "Amaron Current 150Ah Battery" rows for one product).
--
-- Fix: DISTINCT ON (product_id), preferring the AMC row when a product has
-- both (AMC is the broader ongoing coverage, same precedence
-- _detect_ticket_type already uses), else the most-recent-expiry warranty row.
create or replace function public.wa_identify_customer(p_org_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer customers;
  v_products jsonb;
  v_open_ticket jsonb;
  v_last_service jsonb;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_identify_customer: % is not a resolvable phone number', p_phone;
  end if;

  select * into v_customer from public.customers where org_id = p_org_id and mobile = v_phone limit 1;

  if v_customer.id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  select coalesce(jsonb_agg(x order by x.expiry_date desc), '[]'::jsonb) into v_products
  from (
    select distinct on (raw.product_id) raw.product_id, raw.product_name, raw.coverage, raw.amc_status, raw.expiry_date
    from (
      select p.id as product_id, p.name as product_name, 'amc' as coverage, ac.status as amc_status, ac.expiry_date
      from public.amc_contracts ac join public.products p on p.id = ac.product_id
      where ac.org_id = p_org_id and ac.customer_id = v_customer.id
      union all
      select p.id as product_id, p.name as product_name, 'warranty' as coverage, null as amc_status, w.expiry_date
      from public.warranties w join public.products p on p.id = w.product_id
      where w.org_id = p_org_id and w.customer_id = v_customer.id
    ) raw
    order by raw.product_id, (raw.coverage = 'amc') desc, raw.expiry_date desc
  ) x;

  select to_jsonb(t) into v_open_ticket
  from (
    select id, status, name_of_complaint, type, created_at
    from public.service_tickets
    where org_id = p_org_id and customer_id = v_customer.id and status not in ('completed', 'cancelled')
    order by created_at desc
    limit 1
  ) t;

  select to_jsonb(t) into v_last_service
  from (
    select id, name_of_complaint, type, updated_at
    from public.service_tickets
    where org_id = p_org_id and customer_id = v_customer.id and status = 'completed'
    order by updated_at desc
    limit 1
  ) t;

  return jsonb_build_object(
    'found', true,
    'customer_id', v_customer.id,
    'name', v_customer.name,
    'phone', v_phone,
    'phone_verified', v_customer.phone_verified,
    'products', v_products,
    'open_ticket', v_open_ticket,
    'last_service', v_last_service
  );
end;
$$;
