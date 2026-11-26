-- Rollback for 20261228100000_referral_sources.sql. Apply in ONE transaction, only on the owner's words.
-- Restores _carry_over_lead_referral to its live body (md5 9a4e65a10d7fe96340ae27f79465a166, captured 2026-11-26).
-- WARNING: dropping the columns loses any customer referrers recorded since the apply; awarded
-- referral_points rows are kept (only the source column is dropped) -- they are real customer balances.

drop function if exists public.create_customer_with_referrer(uuid, text, text, jsonb, jsonb, uuid, uuid);
drop function if exists public.create_sale_with_referrer(uuid, uuid, jsonb, uuid, integer, uuid, numeric, uuid, uuid, text, text);
drop function if exists public.create_complaint_ticket_with_referrer(uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, text, text);
drop function if exists public.sell_amc_plan_with_referrer(uuid, uuid, uuid, uuid, date, integer, uuid, boolean, uuid, uuid, text, text);
drop function if exists public._record_transaction_referrer(uuid, uuid, uuid, uuid, text, text, text);
drop function if exists public._validate_referrer(uuid, uuid, uuid, uuid, text);
drop function if exists public._apply_customer_referrer(uuid, uuid, uuid);

drop trigger if exists invoices_customer_referral_points on public.invoices;
drop function if exists public._trg_invoice_customer_referral_points();
drop function if exists public._maybe_award_customer_referral(uuid);
drop index if exists public.referral_points_customer_referral_once_idx;
alter table public.referral_points drop column if exists source;
alter table public.settings drop constraint if exists settings_customer_referral_points_range;
alter table public.settings drop column if exists customer_referral_points_enabled, drop column if exists customer_referral_points;

drop trigger if exists aaa_guard_leads_referred_by_customer_id on public.leads;
drop function if exists public._guard_leads_referred_by_customer_id();
drop trigger if exists aaa_guard_customers_referred_by_customer_id on public.customers;
drop function if exists public._guard_customers_referred_by_customer_id();

alter table public.leads drop constraint if exists leads_referrer_customer_not_self;
alter table public.customers drop constraint if exists customers_referrer_one_kind, drop constraint if exists customers_referrer_not_self;
alter table public.leads drop column if exists referred_by_customer_id;
alter table public.customers drop column if exists referred_by_customer_id;

CREATE OR REPLACE FUNCTION public._carry_over_lead_referral(p_org_id uuid, p_lead_id uuid, p_customer_id uuid, p_mobile text, p_referred_by_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- NOTE: is_local=true scopes this flag to the current transaction, not the session -- it must
  -- never be set except immediately before this one UPDATE, and must never be composed with any
  -- other write to customers.referred_by_user_id inside the same transaction (that write would
  -- silently bypass the guard too, since the flag stays 'on' until the transaction ends).
  perform set_config('app.allow_referral_correction', 'on', true);
  update public.customers
    set referred_by_user_id = p_referred_by_user_id
    where id = p_customer_id and referred_by_user_id is null;
end;
$function$;
revoke all on function public._carry_over_lead_referral(uuid, uuid, uuid, text, uuid) from public, anon, authenticated;
