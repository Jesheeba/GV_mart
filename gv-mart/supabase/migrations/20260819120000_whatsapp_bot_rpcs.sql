-- WhatsApp Integration, Phase 1 — bot-facing RPCs.
--
-- Decision #3: the bot's Edge Function calls Postgres with the service_role
-- key — there is no auth.uid(), so current_org_id()/is_staff()/is_ops_staff()
-- (all keyed off auth.uid() -> profiles) don't apply here. Every function
-- below takes an explicit p_org_id and is SECURITY DEFINER with no grant to
-- authenticated — reachable only via the service-role key the Edge Function
-- holds, same shape _whatsapp_lead_upsert (20260715210000) already uses.

-- ── Phone normalization at the WhatsApp boundary only (see the phone-format
-- constraint migration for why customers.mobile itself is untouched) ────────
-- Meta's inbound `from` arrives as country-code-prefixed digits with no "+"
-- (e.g. "919884012345"). This strips a leading "91" down to the bare
-- 10-digit form customers.mobile is stored in. Returns null for anything
-- that doesn't resolve to a clean 10-digit Indian mobile number, so callers
-- can distinguish "not found" from "malformed input" rather than silently
-- matching nothing.
create or replace function public._wa_normalize_phone(p_raw text)
returns text
language sql
immutable
as $$
  select case
    when p_raw is null then null
    when regexp_replace(p_raw, '\D', '', 'g') ~ '^\d{10}$'
      then regexp_replace(p_raw, '\D', '', 'g')
    when regexp_replace(p_raw, '\D', '', 'g') ~ '^91\d{10}$'
      then substring(regexp_replace(p_raw, '\D', '', 'g') from 3)
    else null
  end;
$$;

grant execute on function public._wa_normalize_phone(text) to authenticated;

-- ── wa_identify_customer — the "recognize this customer" call every journey
-- starts with: customer + their products (from amc_contracts/warranties,
-- the only two tables that actually record a customer-product relationship
-- in this schema — same source _detect_ticket_type reads) + AMC status +
-- open ticket + last completed service, in one call. ──────────────────────
create or replace function public.wa_identify_customer(p_org_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer customers;
  v_products jsonb;
  v_open_ticket jsonb;
  v_last_service jsonb;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_identify_customer: % is not a resolvable phone number', p_phone;
  end if;

  select * into v_customer from public.customers where org_id = p_org_id and mobile = v_phone limit 1;

  if v_customer.id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  select coalesce(jsonb_agg(x order by x.expiry_date desc), '[]'::jsonb) into v_products
  from (
    select p.id as product_id, p.name as product_name, 'amc' as coverage, ac.status as amc_status, ac.expiry_date
    from public.amc_contracts ac join public.products p on p.id = ac.product_id
    where ac.org_id = p_org_id and ac.customer_id = v_customer.id
    union all
    select p.id as product_id, p.name as product_name, 'warranty' as coverage, null as amc_status, w.expiry_date
    from public.warranties w join public.products p on p.id = w.product_id
    where w.org_id = p_org_id and w.customer_id = v_customer.id
  ) x;

  select to_jsonb(t) into v_open_ticket
  from (
    select id, status, name_of_complaint, type, created_at
    from public.service_tickets
    where org_id = p_org_id and customer_id = v_customer.id and status not in ('completed', 'cancelled')
    order by created_at desc
    limit 1
  ) t;

  select to_jsonb(t) into v_last_service
  from (
    select id, name_of_complaint, type, updated_at
    from public.service_tickets
    where org_id = p_org_id and customer_id = v_customer.id and status = 'completed'
    order by updated_at desc
    limit 1
  ) t;

  return jsonb_build_object(
    'found', true,
    'customer_id', v_customer.id,
    'name', v_customer.name,
    'phone', v_phone,
    'phone_verified', v_customer.phone_verified,
    'products', v_products,
    'open_ticket', v_open_ticket,
    'last_service', v_last_service
  );
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only (decision #3).

-- ── Conversation state CRUD (decision #1: Postgres) ─────────────────────────
-- One active conversation per phone, enforced by the partial unique index on
-- whatsapp_conversations. wa_get_conversation creates the row on first
-- contact rather than requiring a separate "start" call, since the webhook
-- always needs one to exist before it can route to journey logic.
create or replace function public.wa_get_conversation(p_org_id uuid, p_phone text)
returns whatsapp_conversations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_row whatsapp_conversations;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_get_conversation: % is not a resolvable phone number', p_phone;
  end if;

  select * into v_row from public.whatsapp_conversations
  where org_id = p_org_id and phone = v_phone and status = 'active'
  limit 1;

  if v_row.id is null then
    insert into public.whatsapp_conversations (org_id, phone, status)
    values (p_org_id, v_phone, 'active')
    returning * into v_row;
  end if;

  return v_row;
end;
$$;

create or replace function public.wa_save_conversation_step(
  p_org_id uuid,
  p_phone text,
  p_journey text,
  p_step text,
  p_collected jsonb default null,
  p_customer_id uuid default null,
  p_status text default 'active'
)
returns whatsapp_conversations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_row whatsapp_conversations;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_save_conversation_step: % is not a resolvable phone number', p_phone;
  end if;
  if p_status not in ('active', 'completed', 'expired', 'handed_off') then
    raise exception 'wa_save_conversation_step: invalid status %', p_status;
  end if;

  update public.whatsapp_conversations
  set journey = coalesce(p_journey, journey),
      step = p_step,
      collected = coalesce(p_collected, collected),
      customer_id = coalesce(p_customer_id, customer_id),
      status = p_status,
      last_message_at = now(),
      updated_at = now()
  where org_id = p_org_id and phone = v_phone and status = 'active'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'wa_save_conversation_step: no active conversation for %, call wa_get_conversation first', v_phone;
  end if;

  return v_row;
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only (decision #3).
