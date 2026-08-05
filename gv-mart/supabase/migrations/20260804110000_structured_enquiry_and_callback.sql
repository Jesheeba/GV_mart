-- Product Enquiry rebuild (2026-08-04), Phase 4: structured per-product
-- quote requests + a new "Request Callback" CTA.
--
-- leads.product_id/qty let a product-detail-page quote request carry which
-- product (and how many) instead of only a free-text note — the admin
-- lead/quotation UI can read these back structurally in a later pass; not
-- redesigning that admin UI here, only adding the data these fields need.
--
-- On de-dup reuse of an existing open lead, only backfill product_id/qty if
-- the existing lead's product_id is null ("first product wins" — the same
-- precedent this migration file's ancestor, 20260715210000_lead_pipeline_
-- completeness.sql, already established for `kind`/`enquiry_type`).
--
-- request_callback is a new sibling RPC, not a reuse of book_service_ticket
-- — a sales callback request must NOT create a service_tickets/appointments
-- row (that table means "a technician visit is scheduled"); it's a sales
-- conversation request, so it becomes a lead + lead_activities note like
-- every other enquiry channel. Slot mechanics are 100% reused from
-- appointment_slots (already admin-configurable, customer-readable) — no
-- new scheduling primitive.

alter table public.leads add column if not exists product_id uuid references public.products (id) on delete set null;
alter table public.leads add column if not exists qty integer;

drop function if exists public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid);

create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null,
  p_product_id uuid default null,
  p_qty integer default null
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
  v_address_id uuid;
  v_existing_product_id uuid;
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
  if p_product_id is not null and not exists (
    select 1 from public.products where id = p_product_id and org_id = p_org_id and is_active
  ) then
    raise exception 'submit_customer_enquiry: product % not found, inactive, or wrong org', p_product_id;
  end if;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

  if v_lead_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status, address_id, product_id, qty)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new', v_address_id, p_product_id,
      case when p_product_id is not null then coalesce(p_qty, 1) end
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;
  elsif p_product_id is not null then
    select product_id into v_existing_product_id from public.leads where id = v_lead_id;
    if v_existing_product_id is null then
      update public.leads set product_id = p_product_id, qty = coalesce(p_qty, 1) where id = v_lead_id;
    end if;
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

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid, uuid, integer) to authenticated;

-- ── request_callback ─────────────────────────────────────────────────────
create or replace function public.request_callback(
  p_org_id uuid,
  p_scheduled_date date,
  p_slot_id uuid,
  p_product_id uuid default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_lead_id uuid;
  v_slot appointment_slots;
  v_note text;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'request_callback: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'request_callback: org mismatch';
  end if;
  if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'request_callback: scheduled date cannot be in the past';
  end if;

  select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
  if v_slot.id is null then
    raise exception 'request_callback: slot % not found or inactive', p_slot_id;
  end if;
  if p_product_id is not null and not exists (
    select 1 from public.products where id = p_product_id and org_id = p_org_id and is_active
  ) then
    raise exception 'request_callback: product % not found, inactive, or wrong org', p_product_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

  if v_lead_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, kind, status, product_id, qty)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', 'product'::public.lead_kind, 'new', p_product_id,
      case when p_product_id is not null then 1 end
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;
  end if;

  v_note := format('Preferred callback: %s %s–%s', p_scheduled_date, v_slot.start_time, v_slot.end_time);
  if p_note is not null and btrim(p_note) <> '' then
    v_note := v_note || format(' — %s', btrim(p_note));
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'callback_requested', v_note);

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'sales_admin', 'callback_requested', 'Callback requested', v_note, v_lead_id);

  return jsonb_build_object('lead_id', v_lead_id, 'scheduled_date', p_scheduled_date, 'slot_name', v_slot.name, 'slot_start_time', v_slot.start_time, 'slot_end_time', v_slot.end_time);
end;
$$;

grant execute on function public.request_callback(uuid, date, uuid, uuid, text) to authenticated;
