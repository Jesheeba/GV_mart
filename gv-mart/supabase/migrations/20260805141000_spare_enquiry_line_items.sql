-- Spare Enquiry multi-product line items (2026-08-05).
--
-- CustomerSpareEnquiryPage now lets a customer request parts for several
-- products in one submission (a "+ Add another product" row, each with its
-- own category/product/spare). Previously `leads` only carried a single
-- scalar product_id/qty/spare_id and submit_customer_enquiry only accepted
-- one product/spare per call, so a multi-product enquiry had nowhere
-- structured to go beyond the free-text note. This adds a `lead_items` child
-- table (mirrors purchase_order_items' shape/RLS, see
-- 20260702170000_automation_purchase_schema.sql) and switches
-- submit_customer_enquiry to a jsonb items array, following the same
-- jsonb_to_recordset pattern create_purchase_order already uses
-- (20260702170100_automation_purchase_functions.sql).
--
-- leads.product_id/qty/spare_id are kept and still populated (from the
-- first item) for backward compatibility with anything still reading those
-- scalar columns directly (e.g. lead list filters) — lead_items is the new
-- source of truth for "everything this enquiry asked for".

create table public.lead_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  lead_id uuid not null references public.leads (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  spare_id uuid references public.spares (id) on delete set null,
  qty integer not null default 1 check (qty > 0),
  created_at timestamptz not null default now()
);

create index lead_items_lead_id_idx on public.lead_items (lead_id);
create index lead_items_org_id_idx on public.lead_items (org_id);

alter table public.lead_items enable row level security;

create policy lead_items_select_staff on public.lead_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy lead_items_write_sales on public.lead_items for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

drop function if exists public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid, uuid, integer, uuid);

create or replace function public.submit_customer_enquiry(
  p_org_id uuid,
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
  v_customer_id uuid;
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

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  end if;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, null);
  v_is_new_lead := v_lead_id is null;

  if v_is_new_lead then
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status, address_id, product_id, qty, spare_id)
    select p_org_id, v_customer_id, c.name, c.mobile, 'customer_app', p_enquiry_type, p_kind::public.lead_kind, 'new', v_address_id, v_first_product_id,
      case when v_first_product_id is not null then v_first_qty end,
      v_first_spare_id
    from public.customers c where c.id = v_customer_id
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

grant execute on function public.submit_customer_enquiry(uuid, text, enquiry_type, text, text, uuid, jsonb) to authenticated;
