-- Map integration (customer address-picker): `addresses.lat`/`lng` already
-- existed in the schema but create_customer_with_details never wrote them,
-- so every address was created with null coordinates. Extend the jsonb
-- payload contract (additive — existing callers omitting lat/lng keep
-- working since ->> on a missing key is null) to accept and store them.
create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source lead_source,
  p_members jsonb, -- [{ name, mobile, is_primary }, ...] — 1..5 entries, exactly one is_primary
  p_address jsonb  -- { door_no, flat_no, street_cross, area, pincode, landmark, district, state, address_type, ownership, lat, lng }
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
    district, state, address_type, ownership, is_primary, lat, lng
  )
  values (
    p_org_id, v_customer_id,
    nullif(p_address ->> 'door_no', ''), nullif(p_address ->> 'flat_no', ''), nullif(p_address ->> 'street_cross', ''),
    nullif(p_address ->> 'area', ''), nullif(p_address ->> 'pincode', ''), nullif(p_address ->> 'landmark', ''),
    nullif(p_address ->> 'district', ''), nullif(p_address ->> 'state', ''),
    coalesce((p_address ->> 'address_type')::address_type, 'residential'),
    coalesce((p_address ->> 'ownership')::ownership_type, 'own'),
    true,
    nullif(p_address ->> 'lat', '')::numeric(9, 6),
    nullif(p_address ->> 'lng', '')::numeric(9, 6)
  );

  return v_customer_id;
end;
$$;

grant execute on function public.create_customer_with_details(uuid, text, lead_source, jsonb, jsonb) to authenticated;
