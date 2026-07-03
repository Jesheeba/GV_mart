-- Phase 3 (ADM-04): atomic customer creation.
--
-- Creating a customer touches three tables (customers, customer_members,
-- addresses). Plain sequential client-side inserts risk a partially-created
-- customer if a later insert fails. SECURITY INVOKER (the default) keeps
-- RLS in force for the calling user — this function does not bypass
-- customers_write_sales / customer_members_write_sales / addresses_write_sales,
-- it just wraps the three inserts in one transaction for atomicity.
create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source lead_source,
  p_members jsonb, -- [{ name, mobile, is_primary }, ...] — 1..5 entries, exactly one is_primary
  p_address jsonb  -- { door_no, flat_no, street_cross, area, pincode, landmark, district, state, address_type, ownership }
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_customer_id uuid;
  v_primary jsonb;
  v_member jsonb;
  v_member_count int;
begin
  select count(*) into v_member_count from jsonb_array_elements(p_members);
  if v_member_count < 1 or v_member_count > 5 then
    raise exception 'create_customer_with_details: members must be between 1 and 5 (got %)', v_member_count;
  end if;

  select m into v_primary from jsonb_array_elements(p_members) m where (m ->> 'is_primary')::boolean is true limit 1;
  if v_primary is null then
    raise exception 'create_customer_with_details: exactly one member must be marked primary';
  end if;

  insert into public.customers (org_id, name, mobile, profession, source)
  values (p_org_id, v_primary ->> 'name', v_primary ->> 'mobile', p_profession, p_source)
  returning id into v_customer_id;

  for v_member in select * from jsonb_array_elements(p_members)
  loop
    insert into public.customer_members (org_id, customer_id, name, mobile, is_primary)
    values (p_org_id, v_customer_id, v_member ->> 'name', v_member ->> 'mobile', (v_member ->> 'is_primary')::boolean);
  end loop;

  insert into public.addresses (
    org_id, customer_id, door_no, flat_no, street_cross, area, pincode, landmark,
    district, state, address_type, ownership, is_primary
  )
  values (
    p_org_id, v_customer_id,
    nullif(p_address ->> 'door_no', ''), nullif(p_address ->> 'flat_no', ''), nullif(p_address ->> 'street_cross', ''),
    nullif(p_address ->> 'area', ''), nullif(p_address ->> 'pincode', ''), nullif(p_address ->> 'landmark', ''),
    nullif(p_address ->> 'district', ''), nullif(p_address ->> 'state', ''),
    coalesce((p_address ->> 'address_type')::address_type, 'residential'),
    coalesce((p_address ->> 'ownership')::ownership_type, 'own'),
    true
  );

  return v_customer_id;
end;
$$;

grant execute on function public.create_customer_with_details(uuid, text, lead_source, jsonb, jsonb) to authenticated;

-- Swaps which customer_member is primary and keeps customers.name/mobile
-- (the denormalized "primary contact" copy) in sync, atomically.
create or replace function public.set_primary_member(p_customer_id uuid, p_member_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_name text;
  v_mobile text;
begin
  update public.customer_members set is_primary = false where customer_id = p_customer_id and is_primary = true;

  update public.customer_members set is_primary = true
  where id = p_member_id and customer_id = p_customer_id
  returning name, mobile into v_name, v_mobile;

  if v_name is null then
    raise exception 'set_primary_member: member % not found on customer %', p_member_id, p_customer_id;
  end if;

  update public.customers set name = v_name, mobile = v_mobile where id = p_customer_id;
end;
$$;

grant execute on function public.set_primary_member(uuid, uuid) to authenticated;
