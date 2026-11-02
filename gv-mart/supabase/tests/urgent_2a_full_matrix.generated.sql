-- GENERATED -- do not hand-edit.
do $outer$
declare
  v_customer1 uuid;
  v_customer2 uuid;
  v_lead_id uuid;
  v_lead_customer uuid;
  v_dedupe_preserved boolean;
  v_other_org_lead_id uuid;
  v_anon_result text;
  v_anon_sqlstate text;
  v_cross_org_result text;
  v_cross_org_sqlstate text;
begin
  perform set_config('lock_timeout', '2000', true);
  perform set_config('request.jwt.claim.sub', '1a7f6469-f20e-4820-8369-cad98662a435', true);

  execute $migration_ddl$
-- 2A: stop new duplicate-customer rows (mobile normalization + advisory
-- lock + double-submit guards) -- REBASED on the current live referral
-- bodies (2026-11-02). The referral window (packages 3/4) already
-- replaced all three functions touched here, adding
-- create_customer_with_details's p_referred_by_user_id param + referral
-- attribution, and _lead_apply_status's/move_lead_to_customer's
-- _carry_over_lead_referral calls. This migration is written against
-- those exact live bodies (freshly re-read, CR-tolerant sha256 pins
-- below) and preserves every referral line byte-for-byte -- only adds
-- normalize-at-write + an advisory lock before each existing dedupe
-- check, exactly as the original 2A scope specified.
--
-- Live pins (CR-tolerant sha256, re-read immediately before writing this
-- file):
--   create_customer_with_details: 65b2a0efa88a95e9cae150c8e50d781d868b7ef452b8b0ee76ee15136acd2627
--   move_lead_to_customer:        fbb0b65969c707675417bbde8f509b6fa5198491783d07359c4196607ccf5fef
--   _lead_apply_status:           16e30ad9fb7aede58d4cce5a213570979016b0b215152b6fd34aae9a318b26d6
--
-- Root cause (unchanged from the original 2A investigation): 609 groups of
-- duplicate customers rows were found live, caused by three insert paths
-- with no real protection against a race: create_customer_with_details
-- (no dedupe check at all, by design -- a manual create is always new),
-- _lead_apply_status and move_lead_to_customer (classic check-then-act:
-- SELECT then INSERT-if-not-found, no lock).
--
-- NOT APPLIED. Needs: rehearsal (as the real authenticated role) +
-- DRYRUN-OK, independent before/after proof, fresh independent
-- string-literal AND security reviews on the final committed scripts,
-- an exercised rollback, an anon-exposure diff, live-definition pins
-- re-checked at apply time, and the owner's typed APPROVED.

-- ── 1. Shared mobile-normalization helper ──────────────────────────────
-- EXECUTE revoked from public/anon below -- this project auto-grants it
-- on new functions by default (20260827 default_privileges_anon_execute_leak
-- fix); always revoke explicitly rather than relying on no default grant.
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

-- ── 2. create_customer_with_details: normalize-at-write + advisory lock ──
-- No new dedupe-and-reuse behaviour -- a manual "Create Customer" is, by
-- design, always a new row. Only the mobile being written is normalized,
-- and the same (org_id, normalized mobile) advisory lock key the other
-- two paths take is taken here too, so a manual create can't land in the
-- middle of a concurrent lead-conversion's check-then-act window for the
-- same org+mobile (and vice versa). Every referral line (p_referred_by_user_id,
-- v_valid_referrer, the self-referral guard, the active-staff/technician
-- validation, referred_by_user_id in the insert, _audit_customer_referral_attributed)
-- is byte-for-byte unchanged from the live body.
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

  -- Urgent item 2A: normalize the mobile being stored, and take the same
  -- (org_id, normalized mobile) advisory lock the two lead-conversion
  -- paths take before their own dedupe check -- this serializes a manual
  -- create against a concurrent "Won"/move-to-customer for the same
  -- org+mobile, even though this function itself still never looks up or
  -- reuses an existing customer. Released automatically at transaction end.
  v_normalized_mobile := public.normalize_mobile(v_primary ->> 'mobile');
  perform pg_advisory_xact_lock(hashtext(p_org_id::text || v_normalized_mobile));

  -- the primary member's own profession fills the customer's when no separate one was passed
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

-- ── 3. _lead_apply_status: advisory lock before the existing dedupe check ─
-- Only the customer-creation branch changes: the SELECT ... WHERE mobile
-- now matches on the normalized mobile, a lock is taken first, and the
-- "if found, reuse that customer" behaviour is otherwise identical.
-- The referral carry-over call (_carry_over_lead_referral) and the final
-- leads UPDATE are byte-for-byte unchanged from the live body.
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

    -- Urgent item 2A: serialize concurrent callers for the same org+mobile
    -- (this path racing against itself, against move_lead_to_customer, or
    -- against a manual create) before the check-then-act below. Released
    -- automatically at transaction end.
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

-- ── 4. move_lead_to_customer: advisory lock before the existing dedupe check ─
-- Identical treatment to _lead_apply_status above. is_sales_staff() guard,
-- quotations re-parent, the referral carry-over call, the audit_log
-- insert, and the lead delete are all byte-for-byte unchanged.
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

    -- Urgent item 2A: same advisory lock key as _lead_apply_status, so the
    -- two lead-conversion paths (and a manual create) serialize against
    -- each other for the same org+mobile instead of racing. Released
    -- automatically at transaction end.
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

  $migration_ddl$;

  -- create a lead in a DIFFERENT org (as privileged connection, setup only)
  insert into leads (org_id, name, mobile, source, status)
  values ('8b87c496-de26-4539-8fc8-3f3e7056d3c3'::uuid, 'ZZ TEST cross-org lead', '9000011122', 'other', 'new')
  returning id into v_other_org_lead_id;

  insert into leads (org_id, name, mobile, source, status)
  values ('b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'ZZ TEST 2A matrix lead', '9123456790', 'other', 'new')
  returning id into v_lead_id;

  -- switch to the REAL sales_admin role for every actual test call
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '1a7f6469-f20e-4820-8369-cad98662a435', true);

  -- 1. normal create -> normalized mobile, no reuse (manual create design unchanged)
  v_customer1 := public.create_customer_with_details(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'ZZ TEST profession', 'other',
    jsonb_build_array(jsonb_build_object('name','ZZ TEST 2A matrix','mobile','+91 91234 56790','is_primary', true)),
    '{}'::jsonb, null
  );
  v_customer2 := public.create_customer_with_details(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'ZZ TEST profession', 'other',
    jsonb_build_array(jsonb_build_object('name','ZZ TEST 2A matrix dup','mobile','9123456790','is_primary', true)),
    '{}'::jsonb, null
  );

  -- 2. lead conversion reuses the FIRST customer with the same normalized mobile (dedupe behaviour unchanged)
  v_lead_customer := public.move_lead_to_customer(v_lead_id);
  v_dedupe_preserved := (v_lead_customer = v_customer1);

  -- 3. CROSS-ORG rejection: sales_admin from org b6822905-5557-4e43-a606-f26ecfd5a541 must not be able to
  -- move a lead belonging to a DIFFERENT org.
  begin
    perform public.move_lead_to_customer(v_other_org_lead_id);
    v_cross_org_result := 'UNEXPECTED SUCCESS -- cross-org lead should not be visible';
  exception when others then
    v_cross_org_result := sqlerrm;
    get stacked diagnostics v_cross_org_sqlstate = returned_sqlstate;
  end;

  -- 4. ANON rejection: no EXECUTE grant at all on move_lead_to_customer.
  reset role;
  set local role anon;
  begin
    perform public.move_lead_to_customer(v_lead_id);
    v_anon_result := 'UNEXPECTED SUCCESS';
  exception when insufficient_privilege then
    v_anon_result := 'correctly rejected';
    get stacked diagnostics v_anon_sqlstate = returned_sqlstate;
  when others then
    v_anon_result := 'rejected with unexpected error: ' || sqlerrm;
    get stacked diagnostics v_anon_sqlstate = returned_sqlstate;
  end;
  reset role;

  raise exception 'RESULTS: customer1=% customer2=% manual_create_no_dedupe=% lead_reuses_existing=% cross_org_result=% cross_org_sqlstate=% anon_result=% anon_sqlstate=%',
    v_customer1, v_customer2, (v_customer1 is distinct from v_customer2), v_dedupe_preserved,
    v_cross_org_result, v_cross_org_sqlstate, v_anon_result, v_anon_sqlstate;
end $outer$;
