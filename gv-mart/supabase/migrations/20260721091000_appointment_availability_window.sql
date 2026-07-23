-- Phase 1.5 of GV_Mart_Technician_Assignment_Logic_Change.md: wire the
-- customer-availability TIME WINDOW columns added in
-- 20260721090000_technician_assignment_phase1_data.sql
-- (appointments.available_from/available_to, plain nullable `time` columns,
-- only meaningful when appointments.mode = 'datetime' — 'always' mode means
-- no time constraint at all and both stay null) into the two RPC entry
-- points that actually negotiate a scheduling window with a customer:
--   - public.create_complaint_ticket (staff-raised ticket, ADM-10)
--   - public.book_service_ticket (customer self-booking, CUST-02)
-- No other appointment-creating RPC is touched — AMC/warranty visit loops
-- (sell_amc_plan, renew_amc_plan, create_sale's AMC add-on,
-- register_product_via_qr's warranty visits) are fixed-cadence
-- auto-scheduled maintenance, not customer-negotiated, and are out of scope
-- per the spec. This is pure plumbing (Phase 1: "make the field real,
-- settable, and populated where relevant") — NO assignment-logic behaviour
-- change.
--
-- Both functions gain exactly two new TRAILING parameters with defaults
-- (p_available_from time default null, p_available_to time default null)
-- and, inside the body, add `available_from, available_to` /
-- `p_available_from, p_available_to` to the existing
-- `insert into public.appointments (...)` column/values lists. Nothing else
-- in either body is changed — bodies below are copied verbatim from their
-- live definitions (re-read in full before writing this migration, not
-- assumed from memory):
--   - create_complaint_ticket: live body is
--     20260703140000_fix_sla_make_interval.sql (only redefinition since its
--     original in 20260702110100_service_amc_functions.sql — confirmed via
--     grep across supabase/migrations, no later migration touches it).
--   - book_service_ticket: live body is
--     20260715210000_lead_pipeline_completeness.sql (the LATEST of three
--     redefinitions — 20260702130100 original, 20260715120000 added
--     auto-assign, 20260715210000 added lead.kind + de-dup — confirmed via
--     grep, no later migration touches it).
--
-- DROP + CREATE, not a bare CREATE OR REPLACE, for both: adding new
-- parameters changes the function's argument-type list, and per Postgres's
-- own CREATE FUNCTION docs, CREATE OR REPLACE FUNCTION "is not possible to
-- change ... argument types of a function this way (if you tried, you would
-- actually be creating a new, distinct function)" — a different argument
-- COUNT is a different signature. This is the exact same gotcha
-- 20260715215000_assigned_at_sla_and_rating_reassignment.sql hit and
-- documented for `_auto_assign_ticket_internal` (2-arg -> 3-arg): naively
-- using CREATE OR REPLACE there would have left the OLD signature in place
-- as a separate overload (both existing 2-arg call sites would keep
-- resolving to the old, unmodified function, or hit "function is not
-- unique"), silently never picking up the new behaviour. The fact that our
-- new parameters carry DEFAULT values does not change this — Postgres's own
-- documented example (`foo(int)` + `foo(int, int default 42)`) is exactly
-- this "arity differs, some trailing params default" shape, and it
-- explicitly creates two distinct overloads, not an in-place replace
-- (verified against current PostgreSQL docs, not assumed). So: drop the old
-- exact-arity signature first, then create the new one — leaving exactly
-- one overload of each function, so every existing positional/named call
-- site (which never passes the two new args) correctly falls through to the
-- new defaults (p_available_from/p_available_to = null), i.e. unchanged
-- behaviour for every caller that doesn't opt in.
--
-- Because DROP FUNCTION removes the catalog row (and its grants) outright,
-- CREATE OR REPLACE afterwards starts with NO grants on the new signature —
-- unlike a signature-preserving CREATE OR REPLACE (where "ownership and
-- permissions of the function do not change" per the same docs). Both
-- functions must therefore be explicitly re-granted to `authenticated`
-- below, matching their original grants (create_complaint_ticket:
-- 20260702110100_service_amc_functions.sql:157-159; book_service_ticket:
-- 20260702130100_customer_app_functions.sql:120-122, re-affirmed unchanged
-- by every later redefinition including 20260715210000).

-- ── create_complaint_ticket ─────────────────────────────────────────────
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean
);

create or replace function public.create_complaint_ticket(
  p_org_id uuid,
  p_customer_id uuid,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_channel ticket_channel,
  p_appointment_mode appointment_mode,
  p_scheduled_at timestamptz,
  p_auto_assign boolean,
  p_available_from time default null,
  p_available_to time default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings settings;
  v_detected jsonb;
  v_type ticket_type;
  v_sla_hours numeric;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_assign_result jsonb;
begin
  if not public.is_ops_staff() then
    raise exception 'create_complaint_ticket: only master or operation_admin may raise a ticket';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_complaint_ticket: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_complaint_ticket: customer % not found', p_customer_id;
  end if;
  if p_name_of_complaint is null or btrim(p_name_of_complaint) = '' then
    raise exception 'create_complaint_ticket: name_of_complaint is required';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_complaint_ticket: no settings row for org %', p_org_id;
  end if;

  v_detected := public._detect_ticket_type(p_org_id, p_customer_id, p_product_id);
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
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour'
  )
  returning id into v_ticket_id;

  if p_appointment_mode is not null then
    if p_appointment_mode = 'datetime' and p_scheduled_at is not null then
      if p_scheduled_at::time < v_settings.work_start or p_scheduled_at::time > v_settings.work_end then
        raise exception 'create_complaint_ticket: appointment time is outside working hours (% - %)', v_settings.work_start, v_settings.work_end;
      end if;
    end if;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status, available_from, available_to)
    values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled', p_available_from, p_available_to)
    returning id into v_appointment_id;
  end if;

  if p_auto_assign and v_appointment_id is not null then
    v_assign_result := public.auto_assign_ticket(v_ticket_id);
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'appointment_id', v_appointment_id,
    'detected_type', v_detected,
    'assign_result', v_assign_result
  );
end;
$$;

grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, timestamptz, boolean, time, time
) to authenticated;

-- ── book_service_ticket ─────────────────────────────────────────────────
drop function if exists public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz
);

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
  p_scheduled_at timestamptz,
  p_available_from time default null,
  p_available_to time default null
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
    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, status, available_from, available_to)
    values (p_org_id, v_ticket_id, p_appointment_mode, p_scheduled_at, 'scheduled', p_available_from, p_available_to)
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
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, appointment_mode, timestamptz, time, time
) to authenticated;
