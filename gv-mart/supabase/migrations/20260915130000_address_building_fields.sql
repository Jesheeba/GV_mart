-- Item B2: address restructure. Reported fields "Flat Number"/"Building
-- Number" turned out to be a single overloaded `flat_no` column ("Flat /
-- Building No." in the UI) — `door_no` already exists separately and is
-- already well-populated (32/33 addresses), so it's left untouched. Splits
-- the overloaded field into three new columns matching what was asked for:
-- Building No., Building Name, Plot No.
--
-- Per the owner's own call: add the new fields and leave old data alone
-- rather than auto-migrating it — flat_no is only populated on 6 of 33
-- addresses, and there's no delimiter convention to reliably auto-split it
-- into the new fields anyway. flat_no is kept (not dropped) so that
-- historical data isn't lost; no form writes it anymore after this
-- migration, and every display consumer still shows it as a fallback for
-- addresses that predate this change (see the same-session frontend diff).
alter table public.addresses add column if not exists building_no text;
alter table public.addresses add column if not exists building_name text;
alter table public.addresses add column if not exists plot_no text;

comment on column public.addresses.flat_no is
  'Deprecated 2026-09-15 (Item B2) — replaced by building_no/building_name/plot_no. No longer written by any form; kept only so pre-existing data (6 of 33 rows) still displays.';

-- create_customer_with_details: verbatim body from
-- 20260703130000_family_member_relation.sql, only change is the address
-- jsonb contract (flat_no -> building_no/building_name/plot_no).
create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source lead_source,
  p_members jsonb, -- [{ name, mobile, is_primary, relation }, ...] — 1..5 entries, exactly one is_primary
  p_address jsonb  -- { door_no, building_no, building_name, plot_no, street_cross, area, pincode, landmark, district, state, address_type, ownership, lat, lng }
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
    insert into public.customer_members (org_id, customer_id, name, mobile, is_primary, relation)
    values (
      p_org_id, v_customer_id, v_member ->> 'name', v_member ->> 'mobile', (v_member ->> 'is_primary')::boolean,
      nullif(v_member ->> 'relation', '')::family_relation
    );
  end loop;

  insert into public.addresses (
    org_id, customer_id, door_no, building_no, building_name, plot_no, street_cross, area, pincode, landmark,
    district, state, address_type, ownership, is_primary, lat, lng
  )
  values (
    p_org_id, v_customer_id,
    nullif(p_address ->> 'door_no', ''), nullif(p_address ->> 'building_no', ''), nullif(p_address ->> 'building_name', ''),
    nullif(p_address ->> 'plot_no', ''), nullif(p_address ->> 'street_cross', ''),
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
