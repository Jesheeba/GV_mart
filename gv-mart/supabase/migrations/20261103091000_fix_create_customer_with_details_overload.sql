-- Fixes a production incident caused by 20261103090000_address_full_address_field.sql.
-- That migration's `create or replace function create_customer_with_details(p_org_id,
-- p_profession, p_source, p_members, p_address)` (5 args) was written against this
-- repo's local migration history, which only knew about the 5-arg signature. The
-- LIVE database had already moved to a 6-arg overload (p_referred_by_user_id uuid
-- default null, with referral validation + normalize_mobile + an advisory lock) added
-- by a migration this worktree never had a local file for (worktree drift — see the
-- 2026-11-03 session's main-branch sync incident). `create or replace` only replaces a
-- function with an IDENTICAL signature, so the 5-arg statement didn't update the real
-- function — it created a brand-new, SECOND overload. Postgres/PostgREST resolves a
-- same-named-args RPC call by preferring the candidate needing no defaults, so the new
-- 5-arg overload would have silently taken over every customer-creation call,
-- bypassing the referral check, normalize_mobile, and the advisory-lock dedupe that
-- the real (6-arg) function depends on.
--
-- Fix: drop the accidental 5-arg overload, and redefine the real 6-arg function
-- (body copied verbatim from the live database as of this fix, confirmed via
-- `supabase db query --remote --read-only`) with its address insert switched from
-- door_no/building_no/building_name/plot_no/street_cross/landmark to full_address,
-- matching the Full Address UI redesign. Everything else — referral validation,
-- normalize_mobile, the advisory lock, the referral-attribution audit call — is
-- untouched.
drop function if exists public.create_customer_with_details(uuid, text, text, jsonb, jsonb);

create or replace function public.create_customer_with_details(
  p_org_id uuid,
  p_profession text,
  p_source text,
  p_members jsonb, -- [{ name, mobile, is_primary, relation, profession, email }, ...] — 1..5 entries, exactly one is_primary
  p_address jsonb, -- { full_address, area, pincode, district, state, address_type, ownership, lat, lng } — may be empty
  p_referred_by_user_id uuid default null
)
returns uuid
language plpgsql
set search_path to 'public'
as $$
declare
  v_customer_id uuid;
  v_primary jsonb;
  v_member jsonb;
  v_member_count int;
  v_has_address boolean;
  v_valid_referrer uuid := null;
  v_normalized_mobile text;
begin
  select count(*) into v_member_count from jsonb_array_elements(p_members);
  if v_member_count < 1 or v_member_count > 5 then
    raise exception 'create_customer_with_details: members must be between 1 and 5 (got %)', v_member_count;
  end if;

  select m into v_primary from jsonb_array_elements(p_members) m where (m ->> 'is_primary')::boolean is true limit 1;
  if v_primary is null then
    raise exception 'create_customer_with_details: exactly one member must be marked primary';
  end if;

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

  select exists (
    select 1 from jsonb_each_text(coalesce(p_address, '{}'::jsonb)) e
    where e.key not in ('address_type', 'ownership') and btrim(coalesce(e.value, '')) <> ''
  ) into v_has_address;

  v_normalized_mobile := public.normalize_mobile(v_primary ->> 'mobile');
  perform pg_advisory_xact_lock(hashtext(p_org_id::text || v_normalized_mobile));

  insert into public.customers (org_id, name, mobile, profession, source, needs_setup, referred_by_user_id)
  values (
    p_org_id, v_primary ->> 'name', v_normalized_mobile,
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
      org_id, customer_id, full_address, area, pincode,
      district, state, address_type, ownership, is_primary, lat, lng
    )
    values (
      p_org_id, v_customer_id,
      nullif(p_address ->> 'full_address', ''),
      nullif(p_address ->> 'area', ''), nullif(p_address ->> 'pincode', ''),
      nullif(p_address ->> 'district', ''), nullif(p_address ->> 'state', ''),
      coalesce((p_address ->> 'address_type')::address_type, 'residential'),
      coalesce((p_address ->> 'ownership')::ownership_type, 'own'),
      true,
      nullif(p_address ->> 'lat', '')::numeric(9, 6),
      nullif(p_address ->> 'lng', '')::numeric(9, 6)
    );
  end if;

  if v_valid_referrer is not null then
    perform public._audit_customer_referral_attributed(v_customer_id);
  end if;

  return v_customer_id;
end;
$$;

grant execute on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb, uuid) to authenticated;
