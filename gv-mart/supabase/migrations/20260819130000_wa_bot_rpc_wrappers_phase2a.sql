-- WhatsApp Integration, Phase 2a — extract the load-bearing logic out of
-- create_complaint_ticket and submit_customer_enquiry into internal
-- helpers with no auth-context check, so the bot's wa_* RPCs (which run
-- with no auth.uid() — see Phase 1's decision #3) can reach the exact same
-- business logic the web app uses, instead of re-implementing it.
--
-- Split rule applied uniformly: anything that checks the CALLING SESSION
-- (is_ops_staff(), current_org_id(), current_customer_id()) stays in the
-- public wrapper, because only the wrapper has a session to check.
-- Everything else — including data-integrity checks like "does this
-- customer really belong to this org" — moves to the internal function,
-- unchanged, since that's real validation both callers need equally.
--
-- Bodies below are copied verbatim from the currently-live definitions
-- (create_complaint_ticket: 20260806130000_complaint_type_spares.sql;
-- submit_customer_enquiry: 20260805141000_spare_enquiry_line_items.sql)
-- with ONLY the auth-check lines removed/relocated — no other line
-- changed. This is what the BEFORE/AFTER proof below verifies.

-- ── create_complaint_ticket split ───────────────────────────────────────
create or replace function public._create_complaint_ticket_internal(
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
  p_auto_assign boolean,
  p_scheduled_date date default null,
  p_slot_id uuid default null,
  p_referred_by_technician_id uuid default null,
  p_unlisted_product_name text default null,
  p_complaint_type_id uuid default null
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
  v_slot appointment_slots;
  v_appointment_snapshot appointments;
  v_lead_id uuid; -- REFERRAL: resolved technician referral, if any
  v_customer_name text;
begin
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

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Service customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Service ticket, referred by technician');
  end if;

  v_detected := public._detect_ticket_type(p_org_id, p_customer_id, p_product_id);
  v_type := (v_detected ->> 'type')::ticket_type;

  v_sla_hours := case p_priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, brand_id, model_id, unlisted_product_name,
    name_of_complaint, nature_of_complaint, complaint_type_id, type, priority, status, channel, sla_due_at, lead_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id, nullif(btrim(coalesce(p_unlisted_product_name, '')), ''),
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), p_complaint_type_id, v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour', v_lead_id
  )
  returning id into v_ticket_id;

  if p_appointment_mode = 'datetime' then
    if p_scheduled_date is null or p_slot_id is null then
      raise exception 'create_complaint_ticket: scheduled date and slot are required for a datetime appointment';
    end if;

    if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
      raise exception 'create_complaint_ticket: scheduled date cannot be in the past';
    end if;

    select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
    if v_slot.id is null then
      raise exception 'create_complaint_ticket: slot % not found or inactive', p_slot_id;
    end if;

    if p_scheduled_date = (now() at time zone 'Asia/Kolkata')::date
       and v_slot.end_time <= (now() at time zone 'Asia/Kolkata')::time then
      raise exception 'create_complaint_ticket: slot % has already ended for today', p_slot_id;
    end if;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, slot_id, status)
    values (p_org_id, v_ticket_id, 'datetime', (p_scheduled_date + v_slot.start_time) at time zone 'Asia/Kolkata', p_slot_id, 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
    end if;
  elsif p_appointment_mode = 'always' then
    insert into public.appointments (org_id, ticket_id, mode, status)
    values (p_org_id, v_ticket_id, 'always', 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public.auto_assign_ticket(v_ticket_id);
    end if;
  end if;

  if v_appointment_id is not null then
    select * into v_appointment_snapshot from public.appointments where id = v_appointment_id;
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'appointment_id', v_appointment_id,
    'detected_type', v_detected,
    'assign_result', v_assign_result,
    'scheduled_at', v_appointment_snapshot.scheduled_at,
    'slot_id', v_appointment_snapshot.slot_id,
    'slot_name', v_slot.name,
    'slot_start_time', v_slot.start_time,
    'slot_end_time', v_slot.end_time
  );
end;
$$;

-- Not granted to authenticated — reachable only through the two wrappers
-- below (create_complaint_ticket calls it as postgres/definer; service_role
-- reaches it through wa_create_service_ticket the same way).

-- create_complaint_ticket: now a thin wrapper. Same 17-param signature as
-- the live version, so CREATE OR REPLACE preserves the existing grant to
-- authenticated and every existing caller's call site is untouched.
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
  p_auto_assign boolean,
  p_scheduled_date date default null,
  p_slot_id uuid default null,
  p_referred_by_technician_id uuid default null,
  p_unlisted_product_name text default null,
  p_complaint_type_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_ops_staff() then
    raise exception 'create_complaint_ticket: only master or operation_admin may raise a ticket';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_complaint_ticket: org mismatch';
  end if;

  return public._create_complaint_ticket_internal(
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, p_nature_of_complaint, p_priority, p_channel, p_appointment_mode, p_auto_assign,
    p_scheduled_date, p_slot_id, p_referred_by_technician_id, p_unlisted_product_name, p_complaint_type_id
  );
end;
$$;

-- ── submit_customer_enquiry split ───────────────────────────────────────
create or replace function public._submit_customer_enquiry_internal(
  p_org_id uuid,
  p_customer_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null,
  p_items jsonb default '[]'::jsonb -- [{product_id, spare_id, qty}, ...]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead_id uuid;
  v_note text;
  v_address_id uuid;
  v_existing_product_id uuid;
  v_item record;
  v_first_product_id uuid;
  v_first_qty integer;
  v_first_spare_id uuid;
  v_is_new_lead boolean;
begin
  if p_kind not in ('product', 'spare') then
    raise exception 'submit_customer_enquiry: invalid kind %', p_kind;
  end if;

  for v_item in
    select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) as x(product_id uuid, spare_id uuid, qty integer)
  loop
    if v_item.product_id is not null and not exists (
      select 1 from public.products where id = v_item.product_id and org_id = p_org_id and is_active
    ) then
      raise exception 'submit_customer_enquiry: product % not found, inactive, or wrong org', v_item.product_id;
    end if;
    if v_item.spare_id is not null and not exists (
      select 1 from public.spares where id = v_item.spare_id and org_id = p_org_id and is_active
    ) then
      raise exception 'submit_customer_enquiry: spare % not found, inactive, or wrong org', v_item.spare_id;
    end if;
    if v_first_product_id is null and v_first_spare_id is null and (v_item.product_id is not null or v_item.spare_id is not null) then
      v_first_product_id := v_item.product_id;
      v_first_spare_id := v_item.spare_id;
      v_first_qty := coalesce(v_item.qty, 1);
    end if;
  end loop;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = p_customer_id) then
    v_address_id := p_address_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, p_customer_id, null);
  v_is_new_lead := v_lead_id is null;

  if v_is_new_lead then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status, address_id, product_id, qty, spare_id)
    select p_org_id, p_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new', v_address_id, v_first_product_id,
      case when v_first_product_id is not null then v_first_qty end,
      v_first_spare_id
    from public.customers c where c.id = p_customer_id
    returning id into v_lead_id;
  elsif v_first_product_id is not null or v_first_spare_id is not null then
    select product_id into v_existing_product_id from public.leads where id = v_lead_id;
    if v_existing_product_id is null then
      update public.leads set product_id = v_first_product_id, qty = v_first_qty, spare_id = v_first_spare_id where id = v_lead_id;
    end if;
  end if;

  insert into public.lead_items (org_id, lead_id, product_id, spare_id, qty)
  select p_org_id, v_lead_id, x.product_id, x.spare_id, coalesce(x.qty, 1)
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) as x(product_id uuid, spare_id uuid, qty integer)
  where x.product_id is not null or x.spare_id is not null;

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

-- submit_customer_enquiry: thin wrapper, same 7-param signature as the
-- live version — CREATE OR REPLACE preserves the existing grant and every
-- existing (customer app) call site is untouched.
create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text,
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null,
  p_items jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'submit_customer_enquiry: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_customer_enquiry: org mismatch';
  end if;

  return public._submit_customer_enquiry_internal(p_org_id, v_customer_id, p_kind, p_enquiry_type, p_description, p_photo_url, p_address_id, p_items);
end;
$$;

-- ── Bot-facing wrappers (decision #3: explicit p_org_id, independent
-- phone-ownership check, SECURITY DEFINER, not granted to authenticated —
-- reachable only via the whatsapp-webhook Edge Function's service-role key) ──

create or replace function public.wa_create_service_ticket(
  p_org_id uuid,
  p_phone text,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_appointment_mode appointment_mode,
  p_auto_assign boolean,
  p_scheduled_date date default null,
  p_slot_id uuid default null,
  p_unlisted_product_name text default null,
  p_complaint_type_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer_id uuid;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_create_service_ticket: % is not a resolvable phone number', p_phone;
  end if;

  select id into v_customer_id from public.customers where org_id = p_org_id and mobile = v_phone;
  if v_customer_id is null then
    raise exception 'wa_create_service_ticket: no customer found for %', v_phone;
  end if;

  return public._create_complaint_ticket_internal(
    p_org_id, v_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id,
    p_name_of_complaint, p_nature_of_complaint, p_priority, 'whatsapp'::ticket_channel, p_appointment_mode, p_auto_assign,
    p_scheduled_date, p_slot_id, null, p_unlisted_product_name, p_complaint_type_id
  );
end;
$$;

create or replace function public.wa_create_spare_enquiry(
  p_org_id uuid,
  p_phone text,
  p_kind text,
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null,
  p_items jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_customer_id uuid;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_create_spare_enquiry: % is not a resolvable phone number', p_phone;
  end if;

  select id into v_customer_id from public.customers where org_id = p_org_id and mobile = v_phone;
  if v_customer_id is null then
    raise exception 'wa_create_spare_enquiry: no customer found for %', v_phone;
  end if;

  return public._submit_customer_enquiry_internal(p_org_id, v_customer_id, p_kind, p_enquiry_type, p_description, p_photo_url, p_address_id, p_items);
end;
$$;

-- wa_create_lead: Sales path. Builds on _whatsapp_lead_upsert
-- (20260715210000_lead_pipeline_completeness.sql), which already does its
-- own phone-keyed find-or-create with no separate "ownership" check needed
-- — the lead's mobile IS the calling phone by construction, so there's no
-- other customer's record this could touch.
create or replace function public.wa_create_lead(
  p_org_id uuid,
  p_phone text,
  p_trigger enquiry_type,
  p_body text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_create_lead: % is not a resolvable phone number', p_phone;
  end if;

  return public._whatsapp_lead_upsert(p_org_id, v_phone, p_trigger, p_body);
end;
$$;

-- Intentionally NOT granted to authenticated on any of the three wa_*
-- functions above — service_role only (decision #3).
