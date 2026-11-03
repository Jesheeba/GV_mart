-- APPLY script for 20261204120000_customer_dedupe_advisory_lock_rebased.sql
-- Guard 1: refuse if already registered. Guard 2: refuse on any drift from
-- the three live pins this migration was reviewed against. Anon-exposure
-- snapshot before/after embedded in the same transaction.

do $guard$
declare
  v_sha1 text; v_sha2 text; v_sha3 text;
begin
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204120000') then
    raise exception 'already registered: migration 20261204120000 has already been applied -- refusing to re-apply';
  end if;

  select encode(sha256(regexp_replace(pg_get_functiondef(p.oid), E'\\r\\n', E'\n', 'g')::bytea), 'hex') into v_sha1
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='create_customer_with_details';
  select encode(sha256(regexp_replace(pg_get_functiondef(p.oid), E'\\r\\n', E'\n', 'g')::bytea), 'hex') into v_sha2
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='move_lead_to_customer';
  select encode(sha256(regexp_replace(pg_get_functiondef(p.oid), E'\\r\\n', E'\n', 'g')::bytea), 'hex') into v_sha3
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='_lead_apply_status';

  if v_sha1 is distinct from '65b2a0efa88a95e9cae150c8e50d781d868b7ef452b8b0ee76ee15136acd2627' then
    raise exception 'DRIFT DETECTED: create_customer_with_details no longer matches the reviewed pin (live=%)', v_sha1;
  end if;
  if v_sha2 is distinct from 'fbb0b65969c707675417bbde8f509b6fa5198491783d07359c4196607ccf5fef' then
    raise exception 'DRIFT DETECTED: move_lead_to_customer no longer matches the reviewed pin (live=%)', v_sha2;
  end if;
  if v_sha3 is distinct from '16e30ad9fb7aede58d4cce5a213570979016b0b215152b6fd34aae9a318b26d6' then
    raise exception 'DRIFT DETECTED: _lead_apply_status no longer matches the reviewed pin (live=%)', v_sha3;
  end if;
end $guard$;

do $anon_before$
begin
  create temp table if not exists zz_anon_before_2a (fn text) on commit drop;
  insert into zz_anon_before_2a
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');
end $anon_before$;

-- ── 1. Shared mobile-normalization helper ──────────────────────────────
create or replace function public.normalize_mobile(p_mobile text)
returns text
language plpgsql
immutable
as $$
declare
  v_digits text;
begin
  if p_mobile is null then
    return null;
  end if;

  v_digits := regexp_replace(p_mobile, '\D', '', 'g');

  if length(v_digits) = 12 and left(v_digits, 2) = '91' then
    v_digits := substr(v_digits, 3);
  elsif length(v_digits) = 11 and left(v_digits, 1) = '0' then
    v_digits := substr(v_digits, 2);
  end if;

  return v_digits;
end;
$$;

comment on function public.normalize_mobile(text) is
  'Strips a mobile number to a bare digit string: removes all non-digits, then drops a leading "91" country code (12 digits) or a single leading "0" trunk prefix (11 digits). Does not validate the result is a 10-digit Indian mobile -- callers rely on each table''s own CHECK constraint for that. Added for urgent item 2A (2026-11-02, rebased on the live referral bodies): the one shared helper used by create_customer_with_details, _lead_apply_status and move_lead_to_customer so their dedupe/lookup keys on customers.mobile are computed consistently.';

revoke all on function public.normalize_mobile(text) from public, anon;
grant execute on function public.normalize_mobile(text) to authenticated, service_role;

-- ── 2. create_customer_with_details ─────────────────────────────────────
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

-- ── 3. _lead_apply_status ────────────────────────────────────────────────
create or replace function public._lead_apply_status(p_lead leads, p_status lead_status, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_customer_id uuid;
  v_normalized_mobile text;
begin
  if p_status = 'won' and p_lead.customer_id is null and p_lead.mobile is not null then
    v_normalized_mobile := public.normalize_mobile(p_lead.mobile);

    perform pg_advisory_xact_lock(hashtext(p_lead.org_id::text || v_normalized_mobile));

    select id into v_customer_id from public.customers where org_id = p_lead.org_id and mobile = v_normalized_mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (p_lead.org_id, p_lead.name, v_normalized_mobile, p_lead.source, true)
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

-- ── 4. move_lead_to_customer ─────────────────────────────────────────────
create or replace function public.move_lead_to_customer(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org_id uuid := public.current_org_id();
  v_lead public.leads;
  v_customer_id uuid;
  v_normalized_mobile text;
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

    v_normalized_mobile := public.normalize_mobile(v_lead.mobile);

    perform pg_advisory_xact_lock(hashtext(v_org_id::text || v_normalized_mobile));

    select id into v_customer_id from public.customers where org_id = v_org_id and mobile = v_normalized_mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (v_org_id, v_lead.name, v_normalized_mobile, v_lead.source, true)
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

-- ── register + anon-exposure diff + confirmation ────────────────────────
insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261204120000', 'customer_dedupe_advisory_lock_rebased', array[]::text[]);

do $anon_after$
declare
  v_new_grants text[];
begin
  create temp table if not exists zz_anon_after_2a (fn text) on commit drop;
  insert into zz_anon_after_2a
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');

  select array_agg(fn) into v_new_grants
  from zz_anon_after_2a
  where fn not in (select fn from zz_anon_before_2a);

  if v_new_grants is not null then
    raise exception 'ANON EXPOSURE REGRESSION: new anon-executable functions after this migration: %', v_new_grants;
  end if;
end $anon_after$;

select
  'applied' as status,
  now() as applied_at,
  (select count(*) from zz_anon_before_2a) as anon_before_count,
  (select count(*) from zz_anon_after_2a) as anon_after_count,
  (select pg_get_function_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='create_customer_with_details') as ccwd_args;
