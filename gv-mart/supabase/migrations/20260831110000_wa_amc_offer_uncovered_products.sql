-- AMC "no active plan" reply enhancement (user report 2026-08-31): the
-- existing whatsapp.amc.none reply ("...on file yet...") was apparently
-- misheard/relayed back as a technical "files not exist" error — no actual
-- error was found anywhere in whatsapp_outbox history for this path (traced
-- exhaustively). Regardless of that root cause, the customer's real ask
-- (state plainly there's no AMC, offer to add one, list the products that
-- qualify) is a genuine gap: identify_customer's existing `products` field
-- is built ONLY from amc_contracts UNION warranties (20260819160000), so a
-- product with NEITHER coverage never appears there at all — there was no
-- way for enterAmcJourney to know what to suggest.
--
-- Fix: wa_identify_customer also returns products_without_amc — every
-- product this customer has actually purchased (invoice_items -> invoices,
-- same join wa_get_purchase_history already uses) that has NO amc_contracts
-- row for them. A product with only warranty coverage still counts as "not
-- in an AMC" (warranty != AMC), matching the customer's literal ask. Same
-- single-call architecture as before — this rides the one wa_identify_
-- customer call already made per inbound message, no second RPC.
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
  v_uncovered_products jsonb;
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

  select coalesce(jsonb_agg(x order by x.product_name), '[]'::jsonb) into v_uncovered_products
  from (
    select distinct p.id as product_id, p.name as product_name
    from public.invoice_items ii
    join public.invoices inv on inv.id = ii.invoice_id
    join public.products p on p.id = ii.item_id and ii.item_type = 'product'
    where inv.org_id = p_org_id and inv.customer_id = v_customer.id
      and not exists (
        select 1 from public.amc_contracts ac
        where ac.org_id = p_org_id and ac.customer_id = v_customer.id and ac.product_id = p.id
      )
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
    'products_without_amc', v_uncovered_products,
    'open_ticket', v_open_ticket,
    'last_service', v_last_service
  );
end;
$$;

-- Intentionally not re-granted — unchanged signature, create-or-replace
-- preserves existing grants (not granted to authenticated — service_role
-- only, same as every wa_* function).
