-- AI/CRM Answer Layer, Phase 1 — 4 new read-only wa_* RPCs so the WhatsApp
-- bot can answer open-ended CRM questions with real data instead of
-- guessing (see supabase/GV_MART_AI_CRM_ANSWER_LAYER_SPEC.md §2). Same
-- security shape as every existing wa_* function (20260819120000,
-- 20260819130000): SECURITY DEFINER, explicit p_org_id (no auth.uid() —
-- these run under the service-role key), phone re-normalized and
-- re-resolved to a customer_id INSIDE each function rather than trusting a
-- customer_id the caller already has, not granted to authenticated.
--
-- Read-only means "not found" is a normal outcome here, not a caller
-- error — same convention as wa_identify_customer (jsonb 'found' field),
-- not wa_create_service_ticket's raise-on-missing (that's a write action,
-- where a bad phone genuinely is a caller bug).
--
-- amc_contracts.status is a STORED column, only kept fresh by
-- refresh_amc_statuses(p_org_id) — which is gated on is_ops_staff() /
-- current_org_id(), both auth.uid()-based, so it can never run from this
-- service-role context. Every status returned below is computed live from
-- expiry_date instead of read off that column, using the exact same
-- threshold logic refresh_amc_statuses itself uses (settings.amc_book_
-- window_days, default 15) — see 20260702150000_phase6_refresh_amc_
-- statuses_fix.sql. warranties has no status column at all (never did),
-- so its live status is a simpler active/expired split — there's no
-- "due soon" concept defined anywhere for warranty coverage.

-- ── shared helper: one customer's full AMC + warranty coverage, computed
-- live. Used directly by wa_get_amc_status, and again by
-- wa_get_purchase_history to annotate each purchased line with its
-- coverage. Not granted to authenticated — reachable only from the two
-- wa_* wrappers below, same pattern as _create_complaint_ticket_internal. ──
create or replace function public._wa_customer_coverage(p_org_id uuid, p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window integer;
  v_result jsonb;
begin
  select amc_book_window_days into v_window from public.settings where org_id = p_org_id;
  v_window := coalesce(v_window, 15);

  select coalesce(jsonb_agg(x order by x.expiry_date), '[]'::jsonb) into v_result
  from (
    select
      ac.id as contract_id,
      p.id as product_id,
      p.name as product_name,
      'amc'::text as coverage,
      (case
        when ac.expiry_date < current_date then 'expired'
        when ac.expiry_date <= current_date + (v_window || ' days')::interval then 'due_soon'
        else 'active'
      end) as status,
      ac.start_date,
      ac.expiry_date,
      ac.next_service_date,
      ap.name as plan_name
    from public.amc_contracts ac
    join public.products p on p.id = ac.product_id
    join public.amc_plans ap on ap.id = ac.plan_id
    where ac.org_id = p_org_id and ac.customer_id = p_customer_id
    union all
    select
      w.id as contract_id,
      p.id as product_id,
      p.name as product_name,
      'warranty'::text as coverage,
      (case when w.expiry_date < current_date then 'expired' else 'active' end) as status,
      w.start_date,
      w.expiry_date,
      w.next_service_date,
      null as plan_name
    from public.warranties w
    join public.products p on p.id = w.product_id
    where w.org_id = p_org_id and w.customer_id = p_customer_id
  ) x;

  return v_result;
end;
$$;

-- Intentionally NOT granted to authenticated — internal helper, service_role only.

-- ── wa_get_amc_status — "what's my AMC status?" / "am I still under
-- warranty?". Includes both amc_contracts and warranties (decision:
-- confirmed with the user rather than assumed — a customer asking about
-- "coverage" doesn't distinguish the two, and there's no separate
-- warranty-status tool in this phase). ─────────────────────────────────────
create or replace function public.wa_get_amc_status(p_org_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer_id uuid;
  v_coverage jsonb;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_get_amc_status: % is not a resolvable phone number', p_phone;
  end if;

  select id into v_customer_id from public.customers where org_id = p_org_id and mobile = v_phone;
  if v_customer_id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  v_coverage := public._wa_customer_coverage(p_org_id, v_customer_id);

  return jsonb_build_object(
    'found', true,
    'customer_id', v_customer_id,
    'coverage', v_coverage
  );
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only.

-- ── wa_get_product_price — "how much is a 25 LPH RO?". No identity check:
-- pricing is public catalog information, same visibility as the product
-- enquiry catalog already exposes to any customer. Name match first
-- (covers "LG AC", specific models), category fallback if that finds
-- nothing (covers "how much is an RO" with no model named). Capped to 5 —
-- this is a tool result an LLM reads and summarizes/asks a follow-up on,
-- not a final answer, so returning several plausible matches is correct
-- behavior, not a bug to fix by picking one. ────────────────────────────────
create or replace function public.wa_get_product_price(p_org_id uuid, p_search text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text;
  v_category text;
  v_results jsonb;
begin
  v_search := nullif(btrim(coalesce(p_search, '')), '');
  if v_search is null then
    return jsonb_build_object('results', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(x order by x.price), '[]'::jsonb) into v_results
  from (
    select p.id as product_id, p.name, b.name as brand, p.category, p.price, p.custom_attributes, p.feature_bullets
    from public.products p
    left join public.brands b on b.id = p.brand_id
    where p.org_id = p_org_id and p.is_active = true and p.name ilike '%' || v_search || '%'
    limit 5
  ) x;

  if jsonb_array_length(v_results) = 0 then
    -- Word-boundary match (not plain substring) so "ac" doesn't false-positive
    -- on "pack"/"attack"/etc. — first enum label that appears as a whole word
    -- in the search text, if any.
    select c into v_category
    from unnest(array['ro', 'ac', 'inverter', 'battery']) as c
    where v_search ~* ('\y' || c || '\y')
    limit 1;

    if v_category is not null then
      select coalesce(jsonb_agg(x order by x.price), '[]'::jsonb) into v_results
      from (
        select p.id as product_id, p.name, b.name as brand, p.category, p.price, p.custom_attributes, p.feature_bullets
        from public.products p
        left join public.brands b on b.id = p.brand_id
        where p.org_id = p_org_id and p.is_active = true and p.category::text = v_category
        limit 5
      ) x;
    end if;
  end if;

  return jsonb_build_object('results', v_results);
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only.

-- ── wa_get_service_ticket_status — "what's the status of my repair?".
-- There is no human-readable ticket reference anywhere in the schema —
-- outbound confirmations only ever showed a cosmetic ticket_id.slice(0,8)
-- (see executeServiceAction in _shared/whatsapp-handle-message.ts), never
-- stored. p_ticket_ref is therefore matched as a UUID prefix, and it is
-- ALWAYS scoped to customer_id = v_customer_id — a customer can never
-- resolve another customer's ticket even by guessing a prefix, regardless
-- of what they type in p_ticket_ref (this is also why no wildcard-
-- escaping is needed on that input: the ownership predicate bounds the
-- blast radius to this one customer's own tickets no matter what). No ref
-- given → the single most recent ticket for that customer (decision:
-- confirmed with the user — most-open-tickets support deferred). ───────────
create or replace function public.wa_get_service_ticket_status(p_org_id uuid, p_phone text, p_ticket_ref text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer_id uuid;
  v_ref text;
  v_ticket jsonb;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_get_service_ticket_status: % is not a resolvable phone number', p_phone;
  end if;

  select id into v_customer_id from public.customers where org_id = p_org_id and mobile = v_phone;
  if v_customer_id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  v_ref := nullif(btrim(coalesce(p_ticket_ref, '')), '');

  select to_jsonb(t) into v_ticket
  from (
    select
      st.id as ticket_id,
      st.status,
      st.name_of_complaint,
      st.nature_of_complaint,
      st.type,
      st.priority,
      st.created_at,
      p.name as product_name,
      ap.scheduled_at,
      sl.name as slot_name,
      sl.start_time as slot_start_time,
      sl.end_time as slot_end_time,
      tp.full_name as technician_name
    from public.service_tickets st
    left join public.products p on p.id = st.product_id
    left join public.appointments ap on ap.ticket_id = st.id
    left join public.appointment_slots sl on sl.id = ap.slot_id
    left join public.technicians tc on tc.id = ap.technician_id
    left join public.profiles tp on tp.id = tc.profile_id
    where st.org_id = p_org_id
      and st.customer_id = v_customer_id
      and (v_ref is null or st.id::text ilike v_ref || '%')
    order by st.created_at desc
    limit 1
  ) t;

  return jsonb_build_object(
    'found', true,
    'customer_id', v_customer_id,
    'ticket', v_ticket
  );
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only.

-- ── wa_get_purchase_history — "what have I bought?". invoice_items →
-- invoices → products, each line annotated with coverage status via the
-- shared helper above (decision: confirmed with the user — folding
-- coverage in here directly answers "what did I buy and is it covered"
-- in one tool call, the natural question shape). ───────────────────────────
create or replace function public.wa_get_purchase_history(p_org_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer_id uuid;
  v_coverage jsonb;
  v_purchases jsonb;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_get_purchase_history: % is not a resolvable phone number', p_phone;
  end if;

  select id into v_customer_id from public.customers where org_id = p_org_id and mobile = v_phone;
  if v_customer_id is null then
    return jsonb_build_object('found', false, 'phone', v_phone);
  end if;

  v_coverage := public._wa_customer_coverage(p_org_id, v_customer_id);

  select coalesce(jsonb_agg(x order by x.purchase_date desc), '[]'::jsonb) into v_purchases
  from (
    select
      p.id as product_id,
      p.name as product_name,
      inv.created_at as purchase_date,
      ii.price as price_paid,
      ii.qty,
      (
        select jsonb_build_object('status', c ->> 'status', 'expiry_date', c ->> 'expiry_date', 'coverage', c ->> 'coverage')
        from jsonb_array_elements(v_coverage) c
        where (c ->> 'product_id')::uuid = p.id
        order by (c ->> 'coverage') -- prefer 'amc' over 'warranty' if a product somehow has both
        limit 1
      ) as coverage
    from public.invoice_items ii
    join public.invoices inv on inv.id = ii.invoice_id
    join public.products p on p.id = ii.item_id and ii.item_type = 'product'
    where inv.org_id = p_org_id and inv.customer_id = v_customer_id
  ) x;

  return jsonb_build_object(
    'found', true,
    'customer_id', v_customer_id,
    'purchases', v_purchases
  );
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only.
