-- Package 4: create_customer_with_details gains p_referred_by_user_id (new, optional, LAST
-- parameter, default null). Rebases the LIVE body (re-read + re-pinned immediately before
-- writing this migration -- see fingerprint_snapshot_before_package4.md) verbatim, plus:
--   - referrer server-side validation (same org as the customer, active, technician-or-staff,
--     not the caller) -- fails loud (RAISE EXCEPTION) on anything invalid, per owner decision for
--     this package specifically (unlike package 3's silent-skip-and-audit carry-over: here the
--     referrer comes directly from a staff-filled form with an active-only picker, so an invalid
--     id reaching the server at all means something bypassed the UI, and the owner wants that
--     surfaced, not swallowed).
--   - first-wins is structural, not enforced by UPDATE: referred_by_user_id is set in the SAME
--     INSERT that creates the customer row, so there is no "existing value" to protect and no
--     need for the app.allow_referral_correction bypass flag at all (the guard trigger's INSERT
--     branch already allows this unconditionally).
--   - one audit_log row when a referral is actually attributed.
--
-- A new parameter list is a DIFFERENT function identity to Postgres (overload by argument
-- types), so CREATE OR REPLACE alone would create a second, ambiguous overload rather than
-- replacing the original -- this migration explicitly DROPs the old 5-argument signature and
-- CREATEs the new 6-argument one in the same migration, matching the owner's instruction.
--
-- Duplicate-customer behaviour (the bare mobile "limit 1" lookup elsewhere in the codebase) is
-- NOT touched by this function at all -- create_customer_with_details only ever INSERTs a new
-- customer row, it never looks one up by mobile -- so there is nothing here for the multi-fix
-- window's duplicate-customer-race fix to rebase against in this file.

drop function if exists public.create_customer_with_details(uuid, text, text, jsonb, jsonb);

create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source text,
  p_members jsonb,
  p_address jsonb,
  p_referred_by_user_id uuid default null
)
returns uuid
language plpgsql
set search_path to 'public'
as $function$
declare
  v_customer_id uuid;
  v_primary jsonb;
  v_member jsonb;
  v_member_count int;
  v_has_address boolean;
  v_valid_referrer uuid := null;
begin
  select count(*) into v_member_count from jsonb_array_elements(p_members);
  if v_member_count < 1 or v_member_count > 5 then
    raise exception 'create_customer_with_details: members must be between 1 and 5 (got %)', v_member_count;
  end if;

  select m into v_primary from jsonb_array_elements(p_members) m where (m ->> 'is_primary')::boolean is true limit 1;
  if v_primary is null then
    raise exception 'create_customer_with_details: exactly one member must be marked primary';
  end if;

  -- Package 4 (additive): validate the referrer, if one was named, BEFORE creating anything.
  -- Fails loud on anything invalid -- the UI's active-only picker should make this unreachable
  -- in normal use; reaching here with a bad id means something bypassed that picker.
  if p_referred_by_user_id is not null then
    if p_referred_by_user_id = auth.uid() then
      raise exception 'create_customer_with_details: a referrer cannot refer themselves';
    end if;

    select pr.id into v_valid_referrer
    from public.profiles pr
    join public.organizations o on o.id = pr.org_id
    where pr.id = p_referred_by_user_id
      and pr.org_id = p_org_id
      and pr.is_active
      and o.name not ilike '%__TEST_%'
      and (
        pr.role in ('master', 'operation_admin', 'sales_admin')
        or (
          pr.role = 'technician'
          and exists (select 1 from public.technicians t where t.profile_id = pr.id and t.is_active)
        )
      );

    if v_valid_referrer is null then
      raise exception 'create_customer_with_details: % is not a valid active technician or staff member in this organisation -- cannot be set as referrer', p_referred_by_user_id;
    end if;
  end if;

  -- Any address text or a map pin counts; address_type/ownership alone don't.
  select exists (
    select 1 from jsonb_each_text(coalesce(p_address, '{}'::jsonb)) e
    where e.key not in ('address_type', 'ownership') and btrim(coalesce(e.value, '')) <> ''
  ) into v_has_address;

  -- the primary member's own profession fills the customer's when no separate one was passed
  -- referred_by_user_id is set HERE, in the same INSERT that creates the row -- first-wins is
  -- structural (there is no pre-existing value to protect), so no update/guard-bypass is needed;
  -- the _guard_customers_referred_by_user_id trigger's INSERT branch allows this unconditionally.
  insert into public.customers (org_id, name, mobile, profession, source, needs_setup, referred_by_user_id)
  values (
    p_org_id, v_primary ->> 'name', v_primary ->> 'mobile',
    coalesce(nullif(p_profession, ''), nullif(btrim(v_primary ->> 'profession'), ''), p_profession),
    p_source, not v_has_address, v_valid_referrer
  )
  returning id into v_customer_id;

  for v_member in select * from jsonb_array_elements(p_members)
  loop
    insert into public.customer_members (org_id, customer_id, name, mobile, is_primary, relation, profession, email)
    values (
      p_org_id, v_customer_id, v_member ->> 'name', v_member ->> 'mobile', (v_member ->> 'is_primary')::boolean,
      nullif(v_member ->> 'relation', '')::family_relation,
      nullif(btrim(v_member ->> 'profession'), ''),
      nullif(btrim(v_member ->> 'email'), '')
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

  -- Package 4 (additive): one audit_log row when a referral was actually attributed.
  if v_valid_referrer is not null then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (p_org_id, auth.uid(), 'referral_attributed_on_create', 'customers', v_customer_id,
            '{}'::jsonb, jsonb_build_object('referred_by_user_id', v_valid_referrer));
  end if;

  return v_customer_id;
end;
$function$;

revoke all on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb, uuid) from public, anon;
grant execute on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb, uuid) to authenticated, service_role;
