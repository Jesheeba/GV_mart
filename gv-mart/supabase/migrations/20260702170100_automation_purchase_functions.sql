-- Phase 9 (Automation, Purchasing & Leads) — RPCs and milestone triggers.

-- ── WhatsApp stub ─────────────────────────────────────────────────────────
-- Every "send" in this codebase is logged, never dispatched (no real
-- WhatsApp Cloud API credentials exist in this environment) — this is the
-- single choke point every feature below goes through, so swapping in a
-- real Edge Function call later only touches this one function.
create or replace function public.send_whatsapp_stub(
  p_org_id uuid,
  p_to_mobile text,
  p_customer_id uuid,
  p_milestone text,
  p_template text,
  p_payload jsonb,
  p_ref_type text,
  p_ref_id uuid
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'send_whatsapp_stub: org mismatch';
  end if;
  if not public.is_staff() then
    raise exception 'send_whatsapp_stub: caller is not staff';
  end if;

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
  values (p_org_id, 'outbound', p_to_mobile, p_customer_id, p_milestone, p_template, coalesce(p_payload, '{}'::jsonb), p_ref_type, p_ref_id, 'sent')
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.send_whatsapp_stub(uuid, text, uuid, text, text, jsonb, text, uuid) to authenticated;

-- ── Milestone notifications (booked, assigned, on-the-way, completed, invoice) ──
-- SECURITY DEFINER: these fire from triggers on tables that ops/sales staff
-- (not necessarily the acting role in every case) write to, and the trigger
-- itself has no "current user" role gate to apply — it just needs to log,
-- so DEFINER bypassing RLS on the write into whatsapp_outbox is correct
-- here (unlike the invoker-only send_whatsapp_stub above, which is called
-- directly by staff from the UI and should stay bound by their own RLS).
create or replace function public._milestone_ticket_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_milestone text;
begin
  if tg_op = 'INSERT' then
    v_milestone := 'booked';
  elsif tg_op = 'UPDATE' and new.status = 'assigned' and old.status is distinct from 'assigned' then
    v_milestone := 'assigned';
  elsif tg_op = 'UPDATE' and new.status = 'completed' and old.status is distinct from 'completed' then
    v_milestone := 'completed';
  else
    return new;
  end if;

  select id, mobile into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_customer.mobile, v_customer.id, v_milestone, 'milestone.' || v_milestone,
            jsonb_build_object('ticket_id', new.id, 'type', new.type), 'service_ticket', new.id, 'sent');
  end if;

  return new;
end;
$$;

drop trigger if exists service_tickets_milestone_notify on public.service_tickets;
create trigger service_tickets_milestone_notify
  after insert or update of status on public.service_tickets
  for each row execute function public._milestone_ticket_notify();

-- "on-the-way" has no dedicated status column anywhere in the schema — the
-- closest real signal is the technician opening the on-site stepper (which
-- creates the `service_visits` row), so that's what this fires on. Noted as
-- a best-effort proxy, not a literal GPS-departure event.
create or replace function public._milestone_visit_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_ticket record;
begin
  select id, customer_id into v_ticket from public.service_tickets where id = new.ticket_id;
  if v_ticket.customer_id is null then
    return new;
  end if;
  select id, mobile into v_customer from public.customers where id = v_ticket.customer_id;
  if v_customer.id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_customer.mobile, v_customer.id, 'on_the_way', 'milestone.on_the_way',
            jsonb_build_object('ticket_id', new.ticket_id, 'technician_id', new.technician_id), 'service_visit', new.id, 'sent');
  end if;
  return new;
end;
$$;

drop trigger if exists service_visits_milestone_notify on public.service_visits;
create trigger service_visits_milestone_notify
  after insert on public.service_visits
  for each row execute function public._milestone_visit_notify();

create or replace function public._milestone_invoice_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
begin
  select id, mobile into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_customer.mobile, v_customer.id, 'invoice', 'milestone.invoice',
            jsonb_build_object('invoice_id', new.id, 'total', new.total, 'type', new.type), 'invoice', new.id, 'sent');
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_milestone_notify on public.invoices;
create trigger invoices_milestone_notify
  after insert on public.invoices
  for each row execute function public._milestone_invoice_notify();

-- ── Purchase Orders (ADM-20) ─────────────────────────────────────────────
create or replace function public.create_purchase_order(
  p_org_id uuid,
  p_supplier_id uuid,
  p_items jsonb -- [{item_type, item_id, qty, price}, ...]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_po_id uuid;
  v_total numeric(12, 2) := 0;
  v_item record;
  v_threshold numeric(12, 2);
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_purchase_order: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_purchase_order: caller is not ops staff';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'create_purchase_order: at least one item is required';
  end if;

  select po_approval_threshold into v_threshold from public.settings where org_id = p_org_id;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (p_org_id, p_supplier_id, 'draft', 0, 'whatsapp')
  returning id into v_po_id;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      continue;
    end if;
    insert into public.purchase_order_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, v_item.item_type, v_item.item_id, v_item.qty, coalesce(v_item.price, 0));
    v_total := v_total + (v_item.qty * coalesce(v_item.price, 0));
  end loop;

  update public.purchase_orders set total = v_total, status = 'sent' where id = v_po_id;

  perform public.send_whatsapp_stub(
    p_org_id, (select whatsapp from public.suppliers where id = p_supplier_id), null,
    'po_sent', 'po.sent', jsonb_build_object('po_id', v_po_id, 'total', v_total), 'purchase_order', v_po_id
  );

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'po', v_po_id, auth.uid(), 'pending');
  end if;

  return v_po_id;
end;
$$;

grant execute on function public.create_purchase_order(uuid, uuid, jsonb) to authenticated;

-- Auto-PO engine (ADM-20 "when stock ≤ min_stock, draft a PO to the
-- cheapest/preferred supplier and send it via WhatsApp"). Fires only on the
-- downward crossing (was above min_stock, now at/below it) so a sale that
-- ships several units in one update doesn't spam duplicate POs, and skips
-- entirely if an open (draft/sent) PO already covers this item so
-- re-checking stock on every subsequent sale doesn't draft duplicates.
create or replace function public._auto_draft_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_supplier_id uuid;
  v_price numeric(12, 2);
  v_po_id uuid;
  v_total numeric(12, 2);
  v_threshold numeric(12, 2);
  v_already_open boolean;
begin
  if new.stock_qty > new.min_stock or (old.stock_qty is not null and old.stock_qty <= old.min_stock) then
    return new;
  end if;

  select exists (
    select 1
    from public.purchase_order_items poi
    join public.purchase_orders po on po.id = poi.po_id
    where po.org_id = new.org_id and po.status in ('draft', 'sent')
      and poi.item_type = new.item_type and poi.item_id = new.item_id
  ) into v_already_open;
  if v_already_open then
    return new;
  end if;

  select supplier_id, price into v_supplier_id, v_price
  from public.supplier_products
  where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id
  order by is_preferred desc, price asc
  limit 1;

  if v_supplier_id is null then
    return new;
  end if;

  select po_approval_threshold into v_threshold from public.settings where org_id = new.org_id;
  v_total := coalesce(v_price, 0) * new.reorder_qty;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (new.org_id, v_supplier_id, 'sent', v_total, 'whatsapp')
  returning id into v_po_id;

  insert into public.purchase_order_items (org_id, po_id, item_type, item_id, qty, price)
  values (new.org_id, v_po_id, new.item_type, new.item_id, new.reorder_qty, coalesce(v_price, 0));

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  values (new.org_id, 'outbound', (select whatsapp from public.suppliers where id = v_supplier_id), 'po_sent', 'po.auto_sent',
          jsonb_build_object('po_id', v_po_id, 'total', v_total, 'item_type', new.item_type, 'item_id', new.item_id),
          'purchase_order', v_po_id, 'sent');

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select new.org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = new.org_id and role = 'master' limit 1;
  end if;

  return new;
end;
$$;

drop trigger if exists inventory_auto_draft_po on public.inventory;
create trigger inventory_auto_draft_po
  after update of stock_qty on public.inventory
  for each row execute function public._auto_draft_purchase_order();

-- ── Bill Entry (ADM-21) ──────────────────────────────────────────────────
-- Posts a supplier bill: line items increment stock (goods received) and
-- the total posts to `expenses` (category 'purchase'). Optionally closes
-- the PO it's fulfilling.
create or replace function public.create_bill_entry(
  p_org_id uuid,
  p_supplier_id uuid,
  p_po_id uuid,
  p_items jsonb, -- [{item_type, item_id, qty, price}, ...]
  p_gst numeric,
  p_bill_date date
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_item record;
  v_subtotal numeric(12, 2) := 0;
  v_expense_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_bill_entry: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_bill_entry: caller is not ops staff';
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty is null or v_item.qty <= 0 then
      continue;
    end if;
    v_subtotal := v_subtotal + (v_item.qty * coalesce(v_item.price, 0));

    update public.inventory
      set stock_qty = stock_qty + v_item.qty
      where org_id = p_org_id and item_type = v_item.item_type and item_id = v_item.item_id;

    if not found then
      insert into public.inventory (org_id, item_type, item_id, stock_qty)
      values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty);
    end if;

    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty, 'purchase_receipt', p_po_id);
  end loop;

  insert into public.expenses (org_id, category, amount, ref_id, date)
  values (p_org_id, 'purchase', v_subtotal + coalesce(p_gst, 0), p_po_id, coalesce(p_bill_date, current_date))
  returning id into v_expense_id;

  if p_po_id is not null then
    update public.purchase_orders set status = 'received' where id = p_po_id and org_id = p_org_id;
  end if;

  return v_expense_id;
end;
$$;

grant execute on function public.create_bill_entry(uuid, uuid, uuid, jsonb, numeric, date) to authenticated;

-- ── Leads (ADM-22) ───────────────────────────────────────────────────────
create or replace function public.log_lead_activity(p_lead_id uuid, p_type text, p_note text)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_id uuid;
begin
  select org_id into v_org_id from public.leads where id = p_lead_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    raise exception 'log_lead_activity: lead % not found', p_lead_id;
  end if;
  if not (public.is_sales_staff() or exists (select 1 from public.leads where id = p_lead_id and owner_id = public.current_technician_id())) then
    raise exception 'log_lead_activity: not permitted';
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (v_org_id, p_lead_id, p_type, p_note)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_lead_activity(uuid, text, text) to authenticated;

create or replace function public.update_lead_status(p_lead_id uuid, p_status public.lead_status)
returns void
language plpgsql
security invoker
as $$
begin
  if not public.is_sales_staff() then
    raise exception 'update_lead_status: caller is not sales staff';
  end if;
  update public.leads set status = p_status
    where id = p_lead_id and org_id = public.current_org_id();
  if not found then
    raise exception 'update_lead_status: lead % not found', p_lead_id;
  end if;
  insert into public.lead_activities (org_id, lead_id, type, note)
  values (public.current_org_id(), p_lead_id, 'status_change', p_status::text);
end;
$$;

grant execute on function public.update_lead_status(uuid, public.lead_status) to authenticated;

-- v2.2 §6.8: referral points, value admin-set (settings.referral_point_value,
-- min 50). Awarded manually by sales staff against a reason (e.g. a lead
-- converting because an existing customer referred them) — there is no
-- automatic "signup implies referral" wiring since lead/customer creation
-- doesn't carry a referrer field anywhere in the existing schema.
create or replace function public.award_referral_points(
  p_org_id uuid,
  p_customer_id uuid,
  p_points integer,
  p_reason text,
  p_ref_id uuid
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'award_referral_points: org mismatch';
  end if;
  if not public.is_sales_staff() then
    raise exception 'award_referral_points: caller is not sales staff';
  end if;
  if p_points is null or p_points <= 0 then
    raise exception 'award_referral_points: points must be positive';
  end if;

  insert into public.referral_points (org_id, customer_id, points, reason, ref_id)
  values (p_org_id, p_customer_id, p_points, p_reason, p_ref_id)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.award_referral_points(uuid, uuid, integer, text, uuid) to authenticated;

-- ── WhatsApp/AI flow builder (ADM-23) ────────────────────────────────────
-- SQL-level stand-in for the spec's `/api/whatsapp/webhook` route: this app
-- is a Vite SPA with no server to host a real HTTP endpoint on, so a real
-- deployment would point an Edge Function webhook at this same function. It
-- matches inbound text to a trigger by simple keyword heuristics (there is
-- no free-text keyword column on `automation_flows` — `trigger` is the
-- `enquiry_type` enum directly), applies the matching flow's action, and
-- falls back to a human-handoff log outside office hours or when nothing
-- matches.
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
