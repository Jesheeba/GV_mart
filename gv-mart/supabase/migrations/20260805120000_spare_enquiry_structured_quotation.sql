-- Spare Enquiry -> Quotation autofill (2026-08-04).
--
-- Structured product_id/qty already exist on leads (see
-- 20260804110000_structured_enquiry_and_callback.sql) but only get
-- populated by the product-detail-page "Request Quotation" CTA. The Spare
-- Enquiry form (CustomerSpareEnquiryPage.tsx) resolves a real product_id +
-- spare_id from its dropdowns but only ever baked them into the free-text
-- lead_activities note, so a "won" spare-enquiry lead had no structured
-- data for the admin's "Create Quotation" button to prefill from. This adds
-- leads.spare_id and threads it through submit_customer_enquiry the same
-- way product_id already flows, so the app layer can start passing it.

alter table public.leads add column if not exists spare_id uuid references public.spares (id) on delete set null;

drop function if exists public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid, uuid, integer);

create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
  p_kind text, -- 'product' | 'spare'
  p_enquiry_type enquiry_type,
  p_description text,
  p_photo_url text,
  p_address_id uuid default null,
  p_product_id uuid default null,
  p_qty integer default null,
  p_spare_id uuid default null
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
  if p_spare_id is not null and not exists (
    select 1 from public.spares where id = p_spare_id and org_id = p_org_id and is_active
  ) then
    raise exception 'submit_customer_enquiry: spare % not found, inactive, or wrong org', p_spare_id;
  end if;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);

  if v_lead_id is null then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status, address_id, product_id, qty, spare_id)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new', v_address_id, p_product_id,
      case when p_product_id is not null then coalesce(p_qty, 1) end,
      p_spare_id
    from public.customers c where c.id = v_customer_id
    returning id into v_lead_id;
  elsif p_product_id is not null then
    select product_id into v_existing_product_id from public.leads where id = v_lead_id;
    if v_existing_product_id is null then
      update public.leads set product_id = p_product_id, qty = coalesce(p_qty, 1), spare_id = p_spare_id where id = v_lead_id;
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

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid, uuid, integer, uuid) to authenticated;
