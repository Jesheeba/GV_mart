-- Segment Builder follow-up fixes (owner-reported + confirmed live 2026-11-18):
--
-- 1. Every historical invoice_items row in this database has item_type = 'spare'; none are
--    'product'. product.name therefore matched nothing against real purchase history — extended
--    below to also match spares by name. product.brand/product.category stay product-only: public.
--    spares has no brand_id or category column, only `name`, so there is nothing to join for those
--    two fields on a spare. This is a genuine data-model limit, not a bug left unfixed.
-- 2. Added an `operator` choice ('=' exact vs 'contains' substring) for every text field, including
--    the new spares branch, instead of every condition being a silent exact match.
-- 3. New RPC audience_segment_field_values() so the UI can suggest real existing values instead of
--    a blind text box (see SegmentsTab.tsx ConditionBuilder's new <datalist>).
--
-- NOTE: audience_segment_match_count(uuid, jsonb) and audience_segment_match_preview(uuid, jsonb,
-- integer) were missing `grant execute ... to authenticated` in 20261204230000_segment_builder.sql
-- (only audience_segment_send_now had it) -- every match count silently showed 0 in the browser
-- because the authenticated role could not call either function at all. That grant was already
-- applied directly to the live database as an urgent fix; the two lines below just bring this
-- migration file back in sync with what is actually live, so a fresh apply from scratch still works.
grant execute on function public.audience_segment_match_count(uuid, jsonb) to authenticated;
grant execute on function public.audience_segment_match_preview(uuid, jsonb, integer) to authenticated;

create or replace function public._segment_leaf_match(p_customer_id uuid, p_org_id uuid, p_field text, p_operator text, p_value jsonb)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_text text := case when jsonb_typeof(p_value) = 'string' then p_value #>> '{}' else null end;
  v_bool boolean := case when jsonb_typeof(p_value) = 'boolean' then (p_value #>> '{}')::boolean else null end;
  v_list text[] := case when jsonb_typeof(p_value) = 'array' then (select array_agg(x) from jsonb_array_elements_text(p_value) x) else null end;
  v_pattern text := case when p_operator = 'contains' then '%' || v_text || '%' else v_text end;
begin
  if p_field = 'customer.city' then
    if p_operator = 'in' then
      return exists (select 1 from public.addresses a where a.customer_id = p_customer_id and a.area = any (v_list));
    end if;
    return exists (select 1 from public.addresses a where a.customer_id = p_customer_id and a.area ilike v_pattern);

  elsif p_field = 'customer.tag' then
    if p_operator = 'contains' then
      return exists (select 1 from public.customers c, unnest(c.tags) tag where c.id = p_customer_id and tag ilike v_pattern);
    end if;
    return v_text = any (select unnest(c.tags) from public.customers c where c.id = p_customer_id);

  elsif p_field = 'lead.status' then
    return exists (select 1 from public.leads l where l.customer_id = p_customer_id and l.status::text = v_text);

  elsif p_field = 'product.brand' then
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      join public.brands b on b.id = p.brand_id
      where i.customer_id = p_customer_id and b.name ilike v_pattern
    );

  elsif p_field = 'product.category' then
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      where i.customer_id = p_customer_id and p.category::text = v_text
    );

  elsif p_field = 'product.name' then
    -- Matches BOTH item_type='product' (public.products) and item_type='spare' (public.spares) --
    -- see migration header: spares carry a purchased item's name even though they have no brand/category.
    return exists (
      select 1 from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id
      left join public.products p on p.id = ii.item_id and ii.item_type = 'product'
      left join public.spares s on s.id = ii.item_id and ii.item_type = 'spare'
      where i.customer_id = p_customer_id
        and coalesce(p.name, s.name) ilike v_pattern
    );

  elsif p_field = 'amc.active' then
    if coalesce(v_bool, true) then
      return exists (select 1 from public.amc_contracts ac where ac.customer_id = p_customer_id and ac.status = 'active');
    end if;
    return not exists (select 1 from public.amc_contracts ac where ac.customer_id = p_customer_id and ac.status = 'active');

  elsif p_field = 'warranty.active' then
    if coalesce(v_bool, true) then
      return exists (select 1 from public.warranties w where w.customer_id = p_customer_id and w.expiry_date >= current_date);
    end if;
    return not exists (select 1 from public.warranties w where w.customer_id = p_customer_id and w.expiry_date >= current_date);

  else
    raise exception 'audience segment: unknown field %', p_field;
  end if;
end;
$$;

-- ── value autocomplete: real existing values per field, for the UI's <datalist> ────────────────
-- Excludes is_test customers the same way match_count/match_preview do, wherever a field is
-- resolved off a customer's own purchase/attribute history (not needed for lead.status/brand/
-- category/name, which are not customer-scoped lookups, but harmless either way).
create or replace function public.audience_segment_field_values(p_org_id uuid, p_field text, p_query text default '')
returns table (value text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_pattern text := '%' || coalesce(p_query, '') || '%';
begin
  if p_field = 'customer.city' then
    return query
      select distinct a.area from public.addresses a
      join public.customers c on c.id = a.customer_id
      where c.org_id = p_org_id and not c.is_test and a.area is not null and a.area ilike v_pattern
      order by 1 limit 20;

  elsif p_field = 'customer.tag' then
    return query
      select distinct tag from public.customers c, unnest(c.tags) tag
      where c.org_id = p_org_id and not c.is_test and tag ilike v_pattern
      order by 1 limit 20;

  elsif p_field = 'lead.status' then
    return query
      select distinct l.status::text from public.leads l
      join public.customers c on c.id = l.customer_id
      where c.org_id = p_org_id and not c.is_test and l.status::text ilike v_pattern
      order by 1 limit 20;

  elsif p_field = 'product.brand' then
    return query
      select distinct b.name from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      join public.brands b on b.id = p.brand_id
      join public.customers c on c.id = i.customer_id
      where c.org_id = p_org_id and not c.is_test and b.name ilike v_pattern
      order by 1 limit 20;

  elsif p_field = 'product.category' then
    return query
      select distinct p.category::text from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id and ii.item_type = 'product'
      join public.products p on p.id = ii.item_id
      join public.customers c on c.id = i.customer_id
      where c.org_id = p_org_id and not c.is_test and p.category::text ilike v_pattern
      order by 1 limit 20;

  elsif p_field = 'product.name' then
    return query
      select distinct coalesce(p.name, s.name) from public.invoices i
      join public.invoice_items ii on ii.invoice_id = i.id
      left join public.products p on p.id = ii.item_id and ii.item_type = 'product'
      left join public.spares s on s.id = ii.item_id and ii.item_type = 'spare'
      join public.customers c on c.id = i.customer_id
      where c.org_id = p_org_id and not c.is_test and coalesce(p.name, s.name) ilike v_pattern
      order by 1 limit 20;

  else
    return;
  end if;
end;
$$;

revoke all on function public.audience_segment_field_values(uuid, text, text) from public;
grant execute on function public.audience_segment_field_values(uuid, text, text) to authenticated;
