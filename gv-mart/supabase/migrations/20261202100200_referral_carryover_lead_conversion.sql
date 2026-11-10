-- Package 3: referral attribution carry-over on lead -> customer conversion.
-- Rebases move_lead_to_customer / _lead_apply_status on their LIVE bodies (pinned + diffed
-- 2026-11-02, re-verified byte-identical to the original pre-referral-feature versions via
-- pg_get_functiondef immediately before writing this migration -- the duplicate-mobile-race
-- fix from the other window has NOT landed as of this migration).
--
-- Ambiguity-safe design (see _local_only/reports/referral_incentives/packages_3_4_rebase_prep.md):
-- 605/609 duplicate-mobile groups in the live data are junk placeholder mobiles shared by
-- unrelated customers (2026-10-16 bulk import). The base lead/customer matching logic (bare
-- "limit 1", untouched here -- not this package's job to fix) can attach a lead to the wrong
-- customer when its mobile is one of those. This migration therefore does NOT trust whatever
-- customer id the base logic resolved to for the purpose of carrying over a referral -- it
-- independently re-checks that the mobile uniquely identifies that exact customer, and skips
-- (with an audit_log row) otherwise. The base lead/customer conversion itself is never blocked
-- or altered by this check.

-- ---------------------------------------------------------------------------------------------
-- 1. New helper: does this org have exactly one non-test customer with this (normalized) mobile,
--    and is it the one the caller already resolved to?
-- ---------------------------------------------------------------------------------------------
create or replace function public.customer_mobile_match_is_unambiguous(p_org_id uuid, p_mobile text)
returns uuid  -- the single matching customer id, or NULL if zero, more-than-one, or no usable mobile
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_key text := public._mobile_key(p_mobile);
  v_candidates uuid[];
begin
  if v_key is null then
    return null;
  end if;

  -- Owner fact (2026-11-02): 605/609 duplicate-mobile groups are junk placeholder mobiles from
  -- the 2026-10-16 bulk import, shared by unrelated customers. "Unambiguous" means exactly ONE
  -- non-test customer in this org currently has this (normalized) mobile.
  select array_agg(id) into v_candidates
  from public.customers
  where org_id = p_org_id and public._mobile_key(mobile) = v_key and not is_test;

  if v_candidates is null or array_length(v_candidates, 1) <> 1 then
    return null;
  end if;

  -- SWAP-IN POINT: placeholder-mobile blocklist. None exists live as of 2026-11-02
  -- (confirmed: to_regclass('public.placeholder_mobiles') is null). Once one ships, add exactly
  -- one check here, e.g.:
  --   if exists (select 1 from public.placeholder_mobiles pm where pm.mobile = p_mobile) then
  --     return null;
  --   end if;
  -- This is the ONLY line that needs to change once that work lands.

  return v_candidates[1];
end;
$$;

revoke all on function public.customer_mobile_match_is_unambiguous(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. Shared carry-over routine, used by both conversion paths below (kept as one function so the
--    ambiguity/history/first-wins logic can never drift between the two call sites).
-- ---------------------------------------------------------------------------------------------
create or replace function public._carry_over_lead_referral(
  p_org_id uuid,
  p_lead_id uuid,
  p_customer_id uuid,
  p_mobile text,
  p_referred_by_user_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_unambiguous_id uuid;
  v_has_history boolean;
begin
  if p_referred_by_user_id is null or p_customer_id is null then
    return;
  end if;

  v_unambiguous_id := public.customer_mobile_match_is_unambiguous(p_org_id, p_mobile);
  v_has_history := public.customer_has_qualifying_history(p_customer_id);

  if v_unambiguous_id is distinct from p_customer_id then
    -- Either the mobile match is ambiguous/placeholder (v_unambiguous_id is null), or it
    -- resolves to a DIFFERENT customer than the one the base conversion logic attached the lead
    -- to -- do nothing, flag, never guess. The lead/customer conversion itself is unaffected.
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (p_org_id, auth.uid(), 'referral_carryover_skipped_ambiguous_mobile', 'leads', p_lead_id,
            jsonb_build_object('mobile', p_mobile, 'resolved_customer_id', p_customer_id),
            jsonb_build_object('reason', 'mobile match is ambiguous, placeholder, or does not resolve to the same customer the lead was attached to -- referral NOT carried over, lead conversion proceeds normally'));
    return;
  end if;

  if v_has_history then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
    values (p_org_id, auth.uid(), 'referral_carryover_skipped_existing_history', 'leads', p_lead_id,
            jsonb_build_object('customer_id', p_customer_id),
            jsonb_build_object('reason', 'customer already has qualifying purchase history before this conversion -- referral NOT carried over'));
    return;
  end if;

  -- First-wins, NULL -> value only; the _guard_customers_referred_by_user_id trigger requires
  -- this flag for any update to referred_by_user_id, including this first-establishment path.
  -- NOTE: is_local=true scopes this flag to the current transaction, not the session -- it must
  -- never be set except immediately before this one UPDATE, and must never be composed with any
  -- other write to customers.referred_by_user_id inside the same transaction (that write would
  -- silently bypass the guard too, since the flag stays 'on' until the transaction ends).
  perform set_config('app.allow_referral_correction', 'on', true);
  update public.customers
    set referred_by_user_id = p_referred_by_user_id
    where id = p_customer_id and referred_by_user_id is null;
end;
$$;

revoke all on function public._carry_over_lead_referral(uuid, uuid, uuid, text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3. move_lead_to_customer -- live body reproduced verbatim, one additive carry-over call
--    inserted after customer resolution, BEFORE the lead row is deleted.
-- ---------------------------------------------------------------------------------------------
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
    -- Same dedupe rule as update_lead_status: reuse a customer with this mobile.
    select id into v_customer_id from public.customers where org_id = v_org_id and mobile = v_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (v_org_id, v_lead.name, v_lead.mobile, v_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  -- Quotes raised against the lead keep working: attach them to the customer.
  update public.quotations set customer_id = v_customer_id
    where lead_id = v_lead.id and customer_id is null;

  -- Package 3 (additive): carry the referral attribution over before the lead row is deleted.
  perform public._carry_over_lead_referral(v_org_id, v_lead.id, v_customer_id, v_lead.mobile, v_lead.referred_by_user_id);

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_org_id, auth.uid(), 'DELETE', 'leads', v_lead.id, to_jsonb(v_lead),
          jsonb_build_object('moved_to_customer_id', v_customer_id));

  delete from public.leads where id = v_lead.id;

  return v_customer_id;
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- 4. _lead_apply_status -- live body reproduced verbatim, one additive carry-over call inserted
--    for the 'won' transition, after the final customer id is known, before the lead row update.
-- ---------------------------------------------------------------------------------------------
create or replace function public._lead_apply_status(p_lead leads, p_status lead_status, p_reason text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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

  -- Package 3 (additive): carry the referral attribution over on the 'won' transition, whether
  -- the customer was just resolved above or the lead already carried a customer_id.
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
