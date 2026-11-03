-- Rollback for 20261204120000_customer_dedupe_advisory_lock_rebased.sql.
-- Restores the exact pre-change bodies (re-read live immediately before
-- writing the forward migration) of create_customer_with_details,
-- _lead_apply_status and move_lead_to_customer, and drops
-- normalize_mobile.

drop function if exists public.normalize_mobile(text);

CREATE OR REPLACE FUNCTION public.create_customer_with_details(p_org_id uuid, p_profession text, p_source text, p_members jsonb, p_address jsonb, p_referred_by_user_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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

  -- the primary member's own profession fills the customer's when no separate one was passed
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

  if v_valid_referrer is not null then
    perform public._audit_customer_referral_attributed(v_customer_id);
  end if;

  return v_customer_id;
end;
$function$;

revoke all on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb, uuid) from public, anon;
grant execute on function public.create_customer_with_details(uuid, text, text, jsonb, jsonb, uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public._lead_apply_status(p_lead leads, p_status lead_status, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
begin
  if p_status = 'won' and p_lead.customer_id is null and p_lead.mobile is not null then
    select id into v_customer_id from public.customers where org_id = p_lead.org_id and mobile = p_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (p_lead.org_id, p_lead.name, p_lead.mobile, p_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  if p_status = 'won' then
    perform public._carry_over_lead_referral(
      p_lead.org_id, p_lead.id, coalesce(v_customer_id, p_lead.customer_id), p_lead.mobile, p_lead.referred_by_user_id
    );
  end if;

  update public.leads
    set status = p_status,
        lost_reason = case when p_status = 'lost' then p_reason else null end,
        customer_id = coalesce(v_customer_id, customer_id)
    where id = p_lead.id;
end;
$function$;

revoke all on function public._lead_apply_status(leads, lead_status, text) from public, anon, authenticated;
grant execute on function public._lead_apply_status(leads, lead_status, text) to service_role;

CREATE OR REPLACE FUNCTION public.move_lead_to_customer(p_lead_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid := public.current_org_id();
  v_lead public.leads;
  v_customer_id uuid;
begin
  if not public.is_sales_staff() then
    raise exception 'move_lead_to_customer: caller is not sales staff';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and org_id = v_org_id;
  if not found then
    raise exception 'move_lead_to_customer: lead % not found', p_lead_id;
  end if;

  v_customer_id := v_lead.customer_id;

  if v_customer_id is null then
    if v_lead.mobile is null or trim(v_lead.mobile) = '' then
      raise exception 'move_lead_to_customer: this lead has no mobile number, so a customer cannot be created from it';
    end if;
    select id into v_customer_id from public.customers where org_id = v_org_id and mobile = v_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (v_org_id, v_lead.name, v_lead.mobile, v_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  update public.quotations set customer_id = v_customer_id
    where lead_id = v_lead.id and customer_id is null;

  perform public._carry_over_lead_referral(v_org_id, v_lead.id, v_customer_id, v_lead.mobile, v_lead.referred_by_user_id);

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_org_id, auth.uid(), 'DELETE', 'leads', v_lead.id, to_jsonb(v_lead),
          jsonb_build_object('moved_to_customer_id', v_customer_id));

  delete from public.leads where id = v_lead.id;

  return v_customer_id;
end;
$function$;

revoke all on function public.move_lead_to_customer(uuid) from public, anon;
grant execute on function public.move_lead_to_customer(uuid) to authenticated, service_role;
