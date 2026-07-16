-- Lead pipeline completeness — 3-part fix, bundled into one migration
-- because all three touch the same tables/call sites:
--
--   Part 1: simulate_inbound_whatsapp (the SQL-level stand-in for a real
--   WhatsApp webhook — see its header comment in
--   20260702170100_automation_purchase_functions.sql) detects a topic
--   keyword and sends an automated reply, but never wrote a `leads` row.
--   Every other enquiry channel (book_service_ticket's unknown-product
--   branch, submit_customer_enquiry) creates a lead — WhatsApp, meant to be
--   the most "automatic" channel, was the one silently dropping enquiries
--   from the pipeline.
--
--   Part 2: `leads` has `enquiry_type` (a marketing *topic* — online/price/
--   quality/customization/water_premium/budget) but no column for which
--   broad *kind* of enquiry it was (service/spare/product/amc). That only
--   lived, inconsistently, in free-text lead_activities.type values — not
--   filterable on the leads list itself. Adds `leads.kind`.
--
--   Part 3: repeat enquiries from the same customer created fully
--   disconnected `leads` rows. Adds a recency-window de-dup check to the
--   same three lead-creation call sites: reuse an existing still-open lead
--   instead of creating a duplicate.
--
-- RECONCILIATION NOTE: book_service_ticket's latest body lives in
-- 20260715120000_auto_assign_customer_and_amc_bookings.sql (adds
-- technician auto-assignment on customer self-bookings). This migration's
-- `create or replace function public.book_service_ticket(...)` is based on
-- THAT version, not the older 20260703140000 one, so the auto-assign fix
-- isn't reverted. submit_customer_enquiry and simulate_inbound_whatsapp were
-- each defined exactly once (20260702130100 and 20260702170100
-- respectively) and never touched again — confirmed via
-- `grep -rl` across supabase/migrations for both names — so those two are
-- based on their original (only) definitions.

-- ── Part 2: leads.kind ────────────────────────────────────────────────────
-- A new enum (matching this codebase's heavy use of pgsql enums for closed
-- value sets — see 20260701090000_extensions_and_enums.sql) rather than a
-- text + check constraint, for consistency with every other
-- closed-vocabulary column in this schema (item_type, invoice_type,
-- ticket_channel, etc.). Nullable: older/ambiguous leads may not cleanly
-- map to any of the four values (see backfill below).
create type public.lead_kind as enum ('service', 'spare', 'product', 'amc');

alter table public.leads add column kind public.lead_kind;

-- Backfill: infer `kind` from each lead's EARLIEST lead_activities row (the
-- activity closest to the lead's own creation most reliably reflects what
-- the lead originally *was* — a later 'note'/'call'/'status_change' bolted
-- on afterward would misclassify it if we picked the most recent instead).
-- Only 'service_enquiry' (book_service_ticket) / 'product_enquiry' /
-- 'spare_enquiry' (submit_customer_enquiry) map cleanly — both call sites
-- have used exactly these type strings since Phase 8/9.
--
-- 'amc' is intentionally left unmapped by this backfill: every AMC-touching
-- function (sell_amc_plan, renew_amc_plan, create_sale's AMC add-on — see
-- 20260702110100_service_amc_functions.sql / 20260702130100_customer_app_
-- functions.sql / 20260702170100_automation_purchase_functions.sql) writes
-- amc_contracts + service_tickets directly and never inserts into `leads`
-- at all, so no lead_activities row anywhere carries an AMC-shaped type to
-- infer 'amc' from. Leads with no matching activity type (no activities at
-- all, or only e.g. a manual 'status_change'/'call'/'note') stay
-- kind = null on purpose — null means "not confidently known," not "none
-- of the above."
with first_activity as (
  select distinct on (la.lead_id) la.lead_id, la.type
  from public.lead_activities la
  order by la.lead_id, la.at asc, la.created_at asc
)
update public.leads l
set kind = case fa.type
    when 'service_enquiry' then 'service'::public.lead_kind
    when 'product_enquiry' then 'product'::public.lead_kind
    when 'spare_enquiry' then 'spare'::public.lead_kind
    else null
  end
from first_activity fa
where fa.lead_id = l.id
  and l.kind is null
  and fa.type in ('service_enquiry', 'product_enquiry', 'spare_enquiry');

-- ── Part 3: shared de-dup helper ──────────────────────────────────────────
-- Used by all three lead-creation call sites below. "Still open" = not yet
-- in a terminal lead_status (won/lost — see 20260701090000_extensions_and_
-- enums.sql: lead_status is 'new'|'contacted'|'quoted'|'won'|'lost', so
-- new/contacted/quoted all count as open). 30-day recency window is a
-- reasonable hardcoded default (no existing settings knob fits this — the
-- only comparable constant, settings.amc_book_window_days, governs AMC
-- renewal eligibility, not lead de-dup — and the task doesn't call for a
-- new admin-configurable setting here).
--
-- Matches on customer_id when known, else falls back to mobile (the
-- WhatsApp path frequently has no customer_id). SECURITY DEFINER + no grant
-- to authenticated: read-only helper, only ever called from the other
-- SECURITY DEFINER functions below (mirrors the
-- _auto_assign_ticket_internal "trusted callers only" pattern from
-- 20260715120000).
create or replace function public._find_recent_open_lead(
  p_org_id uuid,
  p_customer_id uuid,
  p_mobile text,
  p_window interval default interval '30 days'
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.leads
  where org_id = p_org_id
    and status not in ('won', 'lost')
    and created_at > now() - p_window
    and (
      (p_customer_id is not null and customer_id = p_customer_id)
      or (p_customer_id is null and p_mobile is not null and customer_id is null and mobile = p_mobile)
    )
  order by created_at desc
  limit 1;
$$;

-- ── Part 1 + 3: WhatsApp lead upsert helper ───────────────────────────────
-- simulate_inbound_whatsapp itself is SECURITY INVOKER, gated on
-- is_staff() (master/operation_admin/sales_admin — see is_staff() in
-- 20260701091200_functions_triggers.sql). But leads' own RLS
-- (leads_write_sales, 20260701091300_rls.sql) only allows *direct* writes
-- from is_sales_staff() (master/sales_admin) — an operation_admin running
-- this WhatsApp simulator would pass simulate_inbound_whatsapp's own gate
-- and then fail RLS on a plain insert. Routing the write through this
-- narrow SECURITY DEFINER helper (analogous to how
-- _auto_assign_ticket_internal lets book_service_ticket reach a
-- staff-only capability on the customer's behalf) avoids that, without
-- widening simulate_inbound_whatsapp's own security mode. No role check of
-- its own: simulate_inbound_whatsapp already validated org + is_staff()
-- before ever calling this, and it is not granted to authenticated.
create or replace function public._whatsapp_lead_upsert(
  p_org_id uuid,
  p_from_mobile text,
  p_trigger public.enquiry_type,
  p_body text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_customer_name text;
  v_lead_id uuid;
  v_note text;
begin
  select c.id, c.name into v_customer_id, v_customer_name
  from public.customers c
  where c.org_id = p_org_id and c.mobile = p_from_mobile
  limit 1;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, p_from_mobile);

  if v_lead_id is null then
    -- leads.name is not null. A raw inbound WhatsApp message carries no
    -- display name — NewLeadForm.tsx's manual lead path requires staff to
    -- type one (min 2 chars, no "unknown" convention to reuse), so there's
    -- no existing fallback pattern in this codebase to follow. Falls back
    -- to the mobile number itself, as suggested by the spec for this task.
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, p_from_mobile), p_from_mobile, 'whatsapp', p_trigger, null, 'new')
    returning id into v_lead_id;
  end if;

  -- kind stays null: a raw WhatsApp topic keyword (price/quality/...) says
  -- nothing about service vs spare vs product.
  v_note := format('[%s] %s', coalesce(p_trigger::text, 'unmatched'), coalesce(p_body, ''));
  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'whatsapp_enquiry', v_note);

  return v_lead_id;
end;
$$;

-- ── Part 1: simulate_inbound_whatsapp ─────────────────────────────────────
-- Unchanged from 20260702170100 except the single new call to
-- _whatsapp_lead_upsert, inserted right after v_trigger is computed and
-- BEFORE the `if v_trigger is null` branch. Placing it there (once) means
-- it's reached by all three remaining `return v_id` paths below —
-- unmatched-trigger (human_handoff), matched-trigger-with-no-active-flow
-- (also human_handoff), and matched-trigger-with-flow-found — without
-- duplicating the insert three times. Only the office-hours-fallback
-- early-return (above, unchanged) still skips lead creation: that's an
-- automated after-hours auto-reply with no real content signal yet, per
-- the task's own carve-out.
create or replace function public.simulate_inbound_whatsapp(
  p_org_id uuid,
  p_from_mobile text,
  p_body text
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_trigger public.enquiry_type;
  v_flow record;
  v_work_start time;
  v_work_end time;
  v_now time := (now() at time zone 'Asia/Kolkata')::time;
  v_id uuid;
  v_template text;
  v_lead_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'simulate_inbound_whatsapp: org mismatch';
  end if;
  if not public.is_staff() then
    raise exception 'simulate_inbound_whatsapp: caller is not staff';
  end if;

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, template, payload, status)
  values (p_org_id, 'inbound', p_from_mobile, 'inbound.raw', jsonb_build_object('body', p_body), 'received')
  returning id into v_id;

  select work_start, work_end into v_work_start, v_work_end from public.settings where org_id = p_org_id;
  if v_work_start is not null and (v_now < v_work_start or v_now > v_work_end) then
    perform public.send_whatsapp_stub(p_org_id, p_from_mobile, null, 'office_hours_fallback', 'flow.office_hours_fallback',
      jsonb_build_object('body', p_body), 'whatsapp_outbox', v_id);
    return v_id;
  end if;

  v_trigger := case
    when p_body ilike '%price%' or p_body ilike '%cost%' or p_body ilike '%quote%' then 'price'
    when p_body ilike '%quality%' or p_body ilike '%durable%' then 'quality'
    when p_body ilike '%custom%' then 'customization'
    when p_body ilike '%premium%' or p_body ilike '%ro %' or p_body ilike '%water%' then 'water_premium'
    when p_body ilike '%budget%' or p_body ilike '%cheap%' or p_body ilike '%discount%' then 'budget'
    when p_body ilike '%online%' or p_body ilike '%website%' then 'online'
    else null
  end;

  -- Part 1/3: log this inbound message as a lead (or as a new activity on
  -- an existing open one) regardless of whether a topic matched — an
  -- unmatched keyword is exactly the case that most needs a human to see it
  -- as a lead, not less.
  v_lead_id := public._whatsapp_lead_upsert(p_org_id, p_from_mobile, v_trigger, p_body);

  if v_trigger is null then
    perform public.send_whatsapp_stub(p_org_id, p_from_mobile, null, 'human_handoff', 'flow.human_handoff',
      jsonb_build_object('body', p_body), 'whatsapp_outbox', v_id);
    return v_id;
  end if;

  select * into v_flow from public.automation_flows
    where org_id = p_org_id and trigger = v_trigger and is_active
    order by created_at desc limit 1;

  if v_flow.id is null then
    perform public.send_whatsapp_stub(p_org_id, p_from_mobile, null, 'human_handoff', 'flow.human_handoff',
      jsonb_build_object('body', p_body, 'matched_trigger', v_trigger), 'whatsapp_outbox', v_id);
    return v_id;
  end if;

  v_template := 'flow.' || v_flow.action::text;
  perform public.send_whatsapp_stub(p_org_id, p_from_mobile, null, 'flow_response', v_template,
    jsonb_build_object('flow_id', v_flow.id, 'trigger', v_trigger, 'action', v_flow.action, 'asset_url', v_flow.asset_url),
    'automation_flows', v_flow.id);

  return v_id;
end;
$$;

grant execute on function public.simulate_inbound_whatsapp(uuid, text, text) to authenticated;

-- ── Part 2 + 3: submit_customer_enquiry ───────────────────────────────────
-- Based on the only-ever definition (20260702130100_customer_app_
-- functions.sql) — confirmed via grep that no later migration touches this
-- function. Adds kind = p_kind (cast to lead_kind; p_kind is already
-- validated above to be 'product'|'spare', both valid lead_kind values) and
-- the same de-dup check as the other two call sites. On de-dup reuse, the
-- existing lead's kind/enquiry_type/name/mobile are intentionally left
-- untouched (first classification wins) — only a new lead_activities row is
-- appended, and the sales_admin notification still fires either way so a
-- repeat enquiry doesn't go unnoticed just because it didn't spawn a new
-- lead row.
create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_lead_id uuid;
  v_note text;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'submit_customer_enquiry: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_customer_enquiry: org mismatch';
  end if;
  if p_kind not in ('product', 'spare') then
    raise exception 'submit_customer_enquiry: invalid kind %', p_kind;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

  if v_lead_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new'
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;
  end if;

  v_note := coalesce(nullif(btrim(p_description), ''), '(no description)');
  if p_photo_url is not null and btrim(p_photo_url) <> '' then
    v_note := v_note || format(' [photo: %s]', p_photo_url);
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, p_kind || '_enquiry', v_note);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'sales_admin', 'enquiry_lead',
    case when p_kind = 'product' then 'New product enquiry' else 'New spare enquiry' end,
    v_note, v_lead_id
  );

  return v_lead_id;
end;
$$;

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text) to authenticated;

-- ── Part 2 + 3: book_service_ticket ───────────────────────────────────────
-- Body based on 20260715120000_auto_assign_customer_and_amc_bookings.sql's
-- version (the latest — already carries that migration's technician
-- auto-assign fix via _auto_assign_ticket_internal), NOT the older
-- 20260703140000 one, so this redefinition doesn't silently revert
-- auto-assignment. Only change from the 20260715120000 body: the
-- unknown-product lead-creation block now sets kind='service' and de-dupes
-- against a recent still-open lead for this customer before inserting.
-- Everything else (auto-assign call, SLA calc, notifications) is verbatim.
create or replace function public.book_service_ticket(
  p_org_id uuid,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_appointment_mode appointment_mode,
  p_scheduled_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_settings settings;
  v_detected jsonb;
  v_type ticket_type;
  v_sla_hours numeric;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_lead_id uuid;
  v_assign_result jsonb;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'book_service_ticket: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'book_service_ticket: org mismatch';
  end if;
  if p_name_of_complaint is null or btrim(p_name_of_complaint) = '' then
    raise exception 'book_service_ticket: issue description is required';
  end if;
  if p_address_id is not null and not exists (
    select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id
  ) then
    raise exception 'book_service_ticket: address % does not belong to this customer', p_address_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'book_service_ticket: no settings row for org %', p_org_id;
  end if;

  v_detected := public._detect_ticket_type(p_org_id, v_customer_id, p_product_id);
  v_type := (v_detected ->> 'type')::ticket_type;

  v_sla_hours := case p_priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, brand_id, model_id,
    name_of_complaint, nature_of_complaint, type, priority, status, channel, sla_due_at
  ) values (
    p_org_id, v_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', 'customer_app',
    now() + v_sla_hours * interval '1 hour'
  )
  returning id into v_ticket_id;

  if p_appointment_mode is not null then
    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status)
    values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled')
    returning id into v_appointment_id;

    -- Auto-assign the self-booked appointment.
    v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
  end if;

  -- Design Deltas §36: unknown product -> also logged as a service enquiry
  -- lead (kind='service'). Part 3: reuse a recent still-open lead for this
  -- customer instead of creating a disconnected duplicate — the repeat
  -- enquiry becomes a new activity on the existing lead's timeline.
  if p_product_id is null then
    v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

    if v_lead_id is null then
      insert into public.leads (org_id, customer_id, name, mobile, source, kind, status)
      select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', 'service', 'new'
      from public.customers c where c.id = v_customer_id
      returning id into v_lead_id;
    end if;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'service_enquiry', p_name_of_complaint);
  end if;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'service_booked', 'New service booking from customer app',
    format('%s', p_name_of_complaint), v_ticket_id
  );

  return jsonb_build_object(
    'ticket_id', v_ticket_id, 'appointment_id', v_appointment_id,
    'detected_type', v_detected, 'lead_id', v_lead_id, 'assign_result', v_assign_result
  );
end;
$$;

grant execute on function public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz
) to authenticated;
