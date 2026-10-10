-- Rollback for 20261012110000_customer_member_email.sql: restores the live pre-migration RPC body and drops the column.
-- Member emails entered since the migration are lost; export first if any exist:
--   select id, customer_id, email from customer_members where email is not null;
create or replace function public.create_customer_with_details(p_org_id uuid, p_profession text, p_source text, p_members jsonb, p_address jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_customer_id uuid;
  v_primary jsonb;
  v_member jsonb;
  v_member_count int;
  v_has_address boolean;
begin
  select count(*) into v_member_count from jsonb_array_elements(p_members);
  if v_member_count < 1 or v_member_count > 5 then
    raise exception 'create_customer_with_details: members must be between 1 and 5 (got %)', v_member_count;
  end if;

  select m into v_primary from jsonb_array_elements(p_members) m where (m ->> 'is_primary')::boolean is true limit 1;
  if v_primary is null then
    raise exception 'create_customer_with_details: exactly one member must be marked primary';
  end if;

  -- Any address text or a map pin counts; address_type/ownership alone don't.
  select exists (
    select 1 from jsonb_each_text(coalesce(p_address, '{}'::jsonb)) e
    where e.key not in ('address_type', 'ownership') and btrim(coalesce(e.value, '')) <> ''
  ) into v_has_address;

  insert into public.customers (org_id, name, mobile, profession, source, needs_setup)
  values (p_org_id, v_primary ->> 'name', v_primary ->> 'mobile', p_profession, p_source, not v_has_address)
  returning id into v_customer_id;

  for v_member in select * from jsonb_array_elements(p_members)
  loop
    insert into public.customer_members (org_id, customer_id, name, mobile, is_primary, relation)
    values (
      p_org_id, v_customer_id, v_member ->> 'name', v_member ->> 'mobile', (v_member ->> 'is_primary')::boolean,
      nullif(v_member ->> 'relation', '')::family_relation
    );
  end loop;

  if v_has_address then
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
  end if;

  return v_customer_id;
end;
$function$;

alter table public.customer_members drop constraint if exists customer_members_email_format;
alter table public.customer_members drop column if exists email;

-- restore the previous ACL ({=X, postgres, service_role, authenticated}): executable by PUBLIC again
grant execute on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb) to public;

notify pgrst, 'reload schema';
