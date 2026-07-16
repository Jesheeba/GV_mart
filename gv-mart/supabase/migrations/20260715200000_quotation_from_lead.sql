-- Lead -> Quotation quick action.
--
-- quotations.lead_id (added in 20260701090900_leads_automation.sql, along
-- with the `quotations_customer_or_lead` check constraint requiring
-- customer_id OR lead_id) has existed since Phase 9 but nothing in the app
-- ever set it: create_quotation() never accepted a lead id, and its
-- p_customer_id parameter was effectively mandatory even though the column
-- itself has always been nullable. That blocked the obvious "create a
-- quotation straight from a lead" action for leads that aren't linked to a
-- customer record yet (a lead can exist with just name/mobile).
--
-- This makes p_customer_id genuinely optional and threads a new p_lead_id
-- through, so a quotation can be created from lead_id alone (customer_id
-- null) or from both when the lead is already linked. Parameter count
-- changes, so the old 4-arg overload is dropped rather than shadowed.
drop function if exists public.create_quotation(uuid, uuid, date, jsonb);

create or replace function public.create_quotation(
  p_org_id uuid,
  p_customer_id uuid,
  p_valid_until date,
  p_items jsonb, -- [{item_type: 'product'|'spare', item_id, qty}]
  p_lead_id uuid default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_quotation_id uuid;
  v_total numeric(12, 2) := 0;
  v_item record;
  v_price numeric(12, 2);
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'create_quotation: at least one item is required';
  end if;

  -- Mirrors the quotations_customer_or_lead check constraint so a bad call
  -- fails with a clear message here rather than a generic constraint error.
  if p_customer_id is null and p_lead_id is null then
    raise exception 'create_quotation: either a customer or a lead is required';
  end if;

  if p_lead_id is not null and not exists (
    select 1 from public.leads where id = p_lead_id and org_id = p_org_id
  ) then
    raise exception 'create_quotation: lead % not found in org %', p_lead_id, p_org_id;
  end if;

  insert into public.quotations (org_id, customer_id, lead_id, status, valid_until, total)
  values (p_org_id, p_customer_id, p_lead_id, 'open', p_valid_until, 0)
  returning id into v_quotation_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(item_type item_type, item_id uuid, qty integer)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      raise exception 'create_quotation: qty must be positive for item %', v_item.item_id;
    end if;

    if v_item.item_type = 'product' then
      select price into v_price from public.products where id = v_item.item_id and org_id = p_org_id;
    else
      select price into v_price from public.spares where id = v_item.item_id and org_id = p_org_id;
    end if;
    if v_price is null then
      raise exception 'create_quotation: item % not found in org %', v_item.item_id, p_org_id;
    end if;

    insert into public.quotation_items (org_id, quotation_id, item_type, item_id, qty, price)
    values (p_org_id, v_quotation_id, v_item.item_type, v_item.item_id, v_item.qty, v_price);

    v_total := v_total + (v_price * v_item.qty);
  end loop;

  update public.quotations set total = v_total where id = v_quotation_id;

  return v_quotation_id;
end;
$$;

grant execute on function public.create_quotation(uuid, uuid, date, jsonb, uuid) to authenticated;
