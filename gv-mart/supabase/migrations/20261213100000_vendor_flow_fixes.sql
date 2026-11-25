-- Vendor flow fixes (build-docs/features/vendor-flow-fixes.md).
--
-- 1. Manual / auto POs over the approval threshold stay DRAFT until a master approves; nothing
--    is sent first. Rejecting a PO approval cancels the draft (new po_status 'cancelled'), so it
--    no longer blocks future auto-reorders for its items.
-- 2. Payment is tracked apart from delivery: purchase_orders.paid_at / paid_by. mark_po_paid no
--    longer changes status, so a PO paid in advance can still be received. unmark_po_paid undoes it.
-- 3. create_bill_entry: warehouse-only stock update, item/supplier/price/GST validation, the PO must
--    belong to the billed supplier, at least one received line, per-line received_qty with a
--    "received short" alert, bill_date stored on the bill.
-- 4. Low-stock trigger only reacts to warehouse stock.
-- 5. Suppliers: is_active (inactive suppliers are not quoted, not fallback winners, not orderable),
--    unique supplier-item link, and every supplier WhatsApp goes through _queue_supplier_whatsapp:
--    normalised 10-digit number or an admin alert, and the org's WhatsApp test mode is respected.
-- 6. Private storage bucket purchase-bill-photos for bill photos/PDFs (ops staff, own org folder).
--
-- Rollback: 20261213100000_vendor_flow_fixes.rollback.sql (the enum value cannot be removed).

-- ── Schema ────────────────────────────────────────────────────────────────
alter type public.po_status add value if not exists 'cancelled';

alter table public.purchase_orders
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null;

alter table public.po_items
  add column if not exists received_qty integer check (received_qty >= 0);

alter table public.purchase_bills
  add column if not exists bill_date date;

alter table public.suppliers
  add column if not exists is_active boolean not null default true;

-- Backfill: the old single status meant "paid" hid whether it was received.
update public.purchase_orders po
   set paid_at = po.updated_at,
       status = case when exists (select 1 from public.purchase_bills b where b.po_id = po.id)
                     then 'received'::public.po_status else 'sent'::public.po_status end
 where po.status = 'paid';

-- Already-received POs were received in full under the old flow (no partial tracking existed).
update public.po_items i set received_qty = i.qty
  from public.purchase_orders po
 where po.id = i.po_id and po.status = 'received' and i.received_qty is null;

update public.purchase_bills b set bill_date = e.date
  from public.expenses e
 where e.ref_id = b.id and b.bill_date is null;
update public.purchase_bills set bill_date = (created_at at time zone 'Asia/Kolkata')::date where bill_date is null;
alter table public.purchase_bills
  alter column bill_date set default ((now() at time zone 'Asia/Kolkata')::date),
  alter column bill_date set not null;

create unique index if not exists supplier_products_supplier_item_uq
  on public.supplier_products (supplier_id, item_type, item_id);

-- ── Helpers ───────────────────────────────────────────────────────────────
create or replace function public._normalize_in_mobile(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when length(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g')) >= 10
              then right(regexp_replace(p, '[^0-9]', '', 'g'), 10) end
$$;

-- Queues one supplier WhatsApp. Returns 'queued', 'no_number' or 'blocked_test_mode'.
create or replace function public._queue_supplier_whatsapp(
  p_org_id uuid, p_supplier_id uuid, p_milestone text, p_template text, p_type text,
  p_payload jsonb, p_ref_type text, p_ref_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to text;
  v_test_on boolean;
  v_test_list text[];
  v_v2 boolean;
begin
  select public._normalize_in_mobile(s.whatsapp) into v_to
    from public.suppliers s where s.id = p_supplier_id and s.org_id = p_org_id;
  if v_to is null then
    return 'no_number';
  end if;

  select s.wa_test_mode_enabled, s.wa_test_allowed_numbers, coalesce(s.wa_dispatch_v2_enabled, false)
    into v_test_on, v_test_list, v_v2
    from public.settings s where s.org_id = p_org_id;
  if coalesce(v_test_on, false) and not (v_to = any (coalesce(v_test_list, '{}'::text[]))) then
    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (p_org_id, auth.uid(), 'WA_SEND_BLOCKED', 'whatsapp_outbox', p_ref_id,
            jsonb_build_object('reason', 'test_mode_not_allow_listed', 'via', '_queue_supplier_whatsapp',
                               'ref_type', p_ref_type, 'template', p_template, 'to_last4', right(v_to, 4)));
    return 'blocked_test_mode';
  end if;

  -- 'pending' for the v2 dispatcher (claims pending rows); with v2 off the legacy dispatcher only
  -- picks up 'sent' rows without a wa_message_id. Same rule as _trg_wa_outbox_pending_normalise.
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, type, payload, ref_type, ref_id, status)
  values (p_org_id, 'outbound', v_to, p_milestone, p_template, p_type, coalesce(p_payload, '{}'::jsonb), p_ref_type, p_ref_id,
          case when v_v2 then 'pending' else 'sent' end);
  return 'queued';
end;
$$;

create or replace function public._notify_po_not_messaged(p_po_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (org_id, role, type, title, body, ref_id)
  select po.org_id, 'operation_admin', 'po_not_messaged', 'Purchase order not sent on WhatsApp',
         format('The purchase order for %s (₹%s) is ready, but the supplier has no valid WhatsApp number. Send it to them by phone or add their number in Suppliers.', s.name, po.total),
         po.id
    from public.purchase_orders po join public.suppliers s on s.id = po.supplier_id
   where po.id = p_po_id;
end;
$$;

-- Sends the "PO approved/sent" message, or raises the admin alert when the supplier has no number.
create or replace function public._send_po_to_supplier(p_po_id uuid, p_template text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
begin
  select * into v_po from public.purchase_orders where id = p_po_id;
  if public._queue_supplier_whatsapp(
       v_po.org_id, v_po.supplier_id, 'po_sent', p_template, null,
       jsonb_build_object('po_id', v_po.id, 'total', v_po.total), 'purchase_order', v_po.id
     ) = 'no_number' then
    perform public._notify_po_not_messaged(v_po.id);
  end if;
end;
$$;

-- Validates one PO/bill line. Raises with the caller's prefix on any problem.
create or replace function public._validate_purchase_line(
  p_fn text, p_org_id uuid, p_item_type public.item_type, p_item_id uuid, p_qty integer, p_price numeric
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_qty is null or p_qty <= 0 then
    raise exception '%: every line needs a quantity above zero', p_fn;
  end if;
  if p_item_type is null or p_item_id is null or public._wa_item_display_name(p_org_id, p_item_type, p_item_id) is null then
    raise exception '%: item not found in your organisation', p_fn;
  end if;
  if p_price is null or p_price <= 0 then
    raise exception '%: every line needs a price above zero', p_fn;
  end if;
end;
$$;

-- ── create_purchase_order: approval before sending ────────────────────────
create or replace function public.create_purchase_order(p_org_id uuid, p_supplier_id uuid, p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po_id uuid;
  v_total numeric(12, 2) := 0;
  v_item record;
  v_threshold numeric(12, 2);
  v_supplier public.suppliers;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_purchase_order: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_purchase_order: caller is not ops staff';
  end if;
  select * into v_supplier from public.suppliers where id = p_supplier_id and org_id = p_org_id;
  if v_supplier.id is null then
    raise exception 'create_purchase_order: supplier not found';
  end if;
  if not v_supplier.is_active then
    raise exception 'create_purchase_order: supplier % is inactive', v_supplier.name;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'create_purchase_order: at least one item is required';
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    perform public._validate_purchase_line('create_purchase_order', p_org_id, v_item.item_type, v_item.item_id, v_item.qty, v_item.price);
  end loop;

  select po_approval_threshold into v_threshold from public.settings where org_id = p_org_id;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (p_org_id, p_supplier_id, 'draft', 0, 'whatsapp')
  returning id into v_po_id;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, v_item.item_type, v_item.item_id, v_item.qty, v_item.price);
    v_total := v_total + (v_item.qty * v_item.price);
  end loop;

  if v_threshold is not null and v_total > v_threshold then
    -- Over the threshold: stays a draft, nothing is sent and no payment task exists until a
    -- master approves (approve_purchase_order / update_po_items_and_approve do the sending).
    update public.purchase_orders set total = v_total where id = v_po_id;

    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'po', v_po_id, auth.uid(), 'pending');

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values
      (p_org_id, 'master', 'po_approval_pending', 'Purchase order awaiting approval',
       format('A purchase order for %s (₹%s) needs your approval before it is sent.', v_supplier.name, v_total), v_po_id),
      (p_org_id, 'operation_admin', 'po_approval_pending', 'Purchase order awaiting approval',
       format('A purchase order for %s (₹%s) is waiting on a master to approve.', v_supplier.name, v_total), v_po_id);
    return v_po_id;
  end if;

  update public.purchase_orders set total = v_total, status = 'sent' where id = v_po_id;
  perform public._create_po_payment_reminder_task(v_po_id);

  if public._normalize_in_mobile(v_supplier.whatsapp) is not null then
    perform public.send_staff_whatsapp(
      p_org_id, v_supplier.whatsapp, null,
      'po_sent', 'po.sent', jsonb_build_object('po_id', v_po_id, 'total', v_total), 'purchase_order', v_po_id
    );
  else
    perform public._notify_po_not_messaged(v_po_id);
  end if;

  return v_po_id;
end;
$$;

-- ── Approvals: send through the helper; reject cancels the draft ──────────
create or replace function public.approve_purchase_order(p_approval_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_approval approvals;
  v_po purchase_orders;
begin
  if not public.is_master() then
    raise exception 'approve_purchase_order: only master may approve a purchase order';
  end if;

  select * into v_approval from public.approvals where id = p_approval_id and org_id = public.current_org_id();
  if v_approval.id is null then
    raise exception 'approve_purchase_order: approval % not found', p_approval_id;
  end if;
  if v_approval.type is distinct from 'po' then
    raise exception 'approve_purchase_order: approval % is not a PO approval', p_approval_id;
  end if;
  if v_approval.status is distinct from 'pending' then
    raise exception 'approve_purchase_order: approval % is not pending', p_approval_id;
  end if;

  select * into v_po from public.purchase_orders where id = v_approval.ref_id and org_id = public.current_org_id();
  if v_po.id is null then
    raise exception 'approve_purchase_order: purchase order % not found', v_approval.ref_id;
  end if;
  if v_po.status is distinct from 'draft' then
    raise exception 'approve_purchase_order: purchase order % is not a pending draft', v_po.id;
  end if;

  update public.approvals set status = 'approved', approver_id = auth.uid()
    where id = p_approval_id and status = 'pending'
    returning * into v_approval;
  if v_approval.id is null then
    raise exception 'approve_purchase_order: approval % was already decided by a concurrent request', p_approval_id;
  end if;

  update public.purchase_orders set status = 'sent', sent_channel = 'whatsapp'
    where id = v_po.id and status = 'draft'
    returning * into v_po;
  if v_po.id is null then
    raise exception 'approve_purchase_order: purchase order % was already sent by a concurrent request', v_approval.ref_id;
  end if;

  perform public._create_po_payment_reminder_task(v_po.id);
  perform public._send_po_to_supplier(v_po.id, 'po.approved_and_sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    v_po.org_id, 'operation_admin', 'low_stock', 'Approved PO sent',
    format('Purchase order %s (₹%s) was approved and sent to the supplier.', v_po.id, v_po.total), v_po.id
  );
end;
$$;

create or replace function public.update_po_items_and_approve(p_approval_id uuid, p_items jsonb default '[]'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_approval public.approvals;
  v_po public.purchase_orders;
  v_item jsonb;
  v_new_total numeric(12, 2);
begin
  if not public.is_master() then
    raise exception 'update_po_items_and_approve: only master may approve a purchase order';
  end if;

  select * into v_approval from public.approvals where id = p_approval_id and org_id = public.current_org_id();
  if v_approval.id is null then
    raise exception 'update_po_items_and_approve: approval % not found', p_approval_id;
  end if;
  if v_approval.type is distinct from 'po' then
    raise exception 'update_po_items_and_approve: approval % is not a PO approval', p_approval_id;
  end if;
  if v_approval.status is distinct from 'pending' then
    raise exception 'update_po_items_and_approve: approval % is not pending', p_approval_id;
  end if;

  select * into v_po from public.purchase_orders where id = v_approval.ref_id and org_id = public.current_org_id();
  if v_po.id is null then
    raise exception 'update_po_items_and_approve: purchase order % not found', v_approval.ref_id;
  end if;
  if v_po.status is distinct from 'draft' then
    raise exception 'update_po_items_and_approve: purchase order % is not a pending draft', v_po.id;
  end if;

  update public.approvals set status = 'approved', approver_id = auth.uid()
    where id = p_approval_id and status = 'pending'
    returning * into v_approval;
  if v_approval.id is null then
    raise exception 'update_po_items_and_approve: approval % was already decided by a concurrent request', p_approval_id;
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    if (v_item ->> 'qty')::integer <= 0 then
      raise exception 'update_po_items_and_approve: quantity must be greater than zero';
    end if;
    update public.po_items
    set qty = (v_item ->> 'qty')::integer, updated_at = now()
    where id = (v_item ->> 'id')::uuid and po_id = v_po.id and org_id = v_po.org_id;
  end loop;

  select coalesce(sum(qty * price), 0) into v_new_total from public.po_items where po_id = v_po.id;

  update public.purchase_orders set status = 'sent', sent_channel = 'whatsapp', total = v_new_total
    where id = v_po.id and status = 'draft'
    returning * into v_po;
  if v_po.id is null then
    raise exception 'update_po_items_and_approve: purchase order % was already sent by a concurrent request', v_approval.ref_id;
  end if;

  perform public._create_po_payment_reminder_task(v_po.id);
  perform public._send_po_to_supplier(v_po.id, 'po.approved_and_sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    v_po.org_id, 'operation_admin', 'low_stock', 'Approved PO sent',
    format('Purchase order %s (₹%s) was approved and sent to the supplier.', v_po.id, v_po.total), v_po.id
  );
end;
$$;

create or replace function public._cancel_po_on_approval_reject()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type = 'po' and new.status = 'rejected' and old.status is distinct from 'rejected' then
    update public.purchase_orders set status = 'cancelled'
     where id = new.ref_id and org_id = new.org_id and status = 'draft';
  end if;
  return new;
end;
$$;

drop trigger if exists approvals_reject_cancels_po on public.approvals;
create trigger approvals_reject_cancels_po
  after update of status on public.approvals
  for each row execute function public._cancel_po_on_approval_reject();

-- ── Auto-reorder: threshold respected on the auto path too ────────────────
create or replace function public._create_po_from_winning_quote(p_org_id uuid, p_item_type item_type, p_item_id uuid, p_order_qty integer, p_supplier_id uuid, p_price numeric, p_inventory_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po_id uuid;
  v_total numeric(12, 2);
  v_threshold numeric(12, 2);
  v_requires_approval boolean;
begin
  select po_approval_threshold, po_requires_approval into v_threshold, v_requires_approval
  from public.settings where org_id = p_org_id;
  v_total := coalesce(p_price, 0) * p_order_qty;

  if coalesce(v_requires_approval, false) or (v_threshold is not null and v_total > v_threshold) then
    insert into public.purchase_orders (org_id, supplier_id, status, total)
    values (p_org_id, p_supplier_id, 'draft', v_total)
    returning id into v_po_id;

    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, p_item_type, p_item_id, p_order_qty, coalesce(p_price, 0));

    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select p_org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = p_org_id and role = 'master' limit 1;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'low_stock', 'Quote resolved — PO awaiting approval',
      format('A supplier quote was resolved and a draft purchase order for %s units needs approval before it sends.', p_order_qty),
      p_inventory_id
    );

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values
      (p_org_id, 'master', 'po_approval_pending', 'Purchase order awaiting approval',
       format('A draft purchase order for %s units (₹%s) needs your approval before it sends.', p_order_qty, v_total), v_po_id),
      (p_org_id, 'operation_admin', 'po_approval_pending', 'Purchase order awaiting approval',
       format('A draft purchase order for %s units (₹%s) is waiting on a master to approve.', p_order_qty, v_total), v_po_id);

    return v_po_id;
  end if;

  insert into public.purchase_orders (org_id, supplier_id, status, total, sent_channel)
  values (p_org_id, p_supplier_id, 'sent', v_total, 'whatsapp')
  returning id into v_po_id;

  insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
  values (p_org_id, v_po_id, p_item_type, p_item_id, p_order_qty, coalesce(p_price, 0));

  perform public._create_po_payment_reminder_task(v_po_id);
  perform public._send_po_to_supplier(v_po_id, 'po.auto_sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'low_stock', 'Quote resolved — PO auto-drafted',
    format('A supplier quote was resolved and a purchase order for %s units was auto-drafted and sent.', p_order_qty),
    p_inventory_id
  );

  return v_po_id;
end;
$$;

create or replace function public._resolve_purchase_quote_requests_core(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req record;
  v_best_supplier uuid;
  v_best_price numeric(12, 2);
  v_po_id uuid;
  v_resolution text;
  v_resolved_count integer := 0;
  v_stock_qty integer;
  v_min_stock integer;
begin
  for v_req in
    select *
    from public.purchase_quote_requests
    where org_id = p_org_id and status = 'open' and timeout_at <= now()
    order by requested_at
    for update skip locked
  loop
    v_best_supplier := null;
    v_best_price := null;

    -- only suppliers that are still active can win
    select r.supplier_id, r.price into v_best_supplier, v_best_price
    from public.purchase_quote_replies r
    join public.suppliers s on s.id = r.supplier_id and s.is_active
    where r.request_id = v_req.id
    order by r.price asc, r.logged_at asc
    limit 1;

    if v_best_supplier is not null then
      v_resolution := 'reply';
    else
      select sp.supplier_id, sp.price into v_best_supplier, v_best_price
      from public.supplier_products sp
      join public.suppliers s on s.id = sp.supplier_id and s.is_active
      where sp.org_id = v_req.org_id and sp.item_type = v_req.item_type and sp.item_id = v_req.item_id
      order by sp.is_preferred desc, sp.price asc
      limit 1;
      v_resolution := 'fallback';
    end if;

    if v_best_supplier is null then
      update public.purchase_quote_requests
      set status = 'resolved', resolved_at = now(), resolution = 'no_supplier', updated_at = now()
      where id = v_req.id;

      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (
        v_req.org_id, 'operation_admin', 'low_stock', 'Quote request expired — no supplier available',
        format('Quote requests for this %s timed out with no replies, and no active supplier is linked to it anymore. Order manually.', v_req.item_type),
        v_req.inventory_id
      );
    else
      select stock_qty, min_stock into v_stock_qty, v_min_stock
      from public.inventory
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id and location = 'warehouse';

      if v_stock_qty is not null and v_stock_qty > v_min_stock then
        update public.purchase_quote_requests
        set status = 'resolved', resolved_at = now(), resolution = 'no_po_not_low_stock', updated_at = now()
        where id = v_req.id;
      else
        v_po_id := public._create_po_from_winning_quote(
          v_req.org_id, v_req.item_type, v_req.item_id, v_req.order_qty, v_best_supplier, v_best_price, v_req.inventory_id
        );

        update public.purchase_quote_requests
        set status = 'resolved', resolved_at = now(), resolved_po_id = v_po_id, resolution = v_resolution, updated_at = now()
        where id = v_req.id;
      end if;
    end if;

    v_resolved_count := v_resolved_count + 1;
  end loop;

  return v_resolved_count;
end;
$$;

-- ── Low-stock trigger: warehouse only, active suppliers, gated sends ──────
create or replace function public._auto_draft_purchase_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_qty integer;
  v_already_open boolean;
  v_has_supplier boolean;
  v_timeout_hours numeric(6, 2);
  v_request_id uuid;
  v_item_name text;
  v_supplier record;
  v_rendered jsonb;
  v_body text;
  v_unreachable integer := 0;
begin
  -- suppliers restock the warehouse; vans are restocked from the warehouse
  if new.location is distinct from 'warehouse' then
    return new;
  end if;
  if new.stock_qty > new.min_stock or (old.stock_qty is not null and old.stock_qty <= old.min_stock) then
    return new;
  end if;

  select exists (
    select 1
    from public.po_items poi
    join public.purchase_orders po on po.id = poi.po_id
    where po.org_id = new.org_id and po.status in ('draft', 'sent')
      and poi.item_type = new.item_type and poi.item_id = new.item_id
  ) or exists (
    select 1 from public.purchase_quote_requests qr
    where qr.org_id = new.org_id and qr.status = 'open'
      and qr.item_type = new.item_type and qr.item_id = new.item_id
  ) into v_already_open;
  if v_already_open then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      new.org_id, 'operation_admin', 'low_stock', 'Stock critical (reorder already in progress)',
      format('Stock for this %s is at %s (min %s). A purchase order or open supplier quote request already covers it.', new.item_type, new.stock_qty, new.min_stock),
      new.id
    );
    return new;
  end if;

  select exists (
    select 1 from public.supplier_products sp
    join public.suppliers s on s.id = sp.supplier_id and s.is_active
    where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id
  ) into v_has_supplier;
  if not v_has_supplier then
    return new;
  end if;

  v_order_qty := greatest(1, new.max_stock - new.stock_qty);
  v_item_name := coalesce(public._wa_item_display_name(new.org_id, new.item_type, new.item_id), 'an item');

  select po_quote_timeout_hours into v_timeout_hours from public.settings where org_id = new.org_id;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
  values (new.org_id, new.id, new.item_type, new.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
  returning id into v_request_id;

  for v_supplier in
    select s.id, s.name
    from public.supplier_products sp
    join public.suppliers s on s.id = sp.supplier_id and s.is_active
    where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id
  loop
    v_rendered := public._wa_render_template(
      new.org_id, 'po.quote_request',
      jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
    );
    v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
      else format('Hi %s, we need a quote for %s (qty: %s). Please reply with your price per unit (and delivery time if possible). - GV Mart', v_supplier.name, v_item_name, v_order_qty)
    end;

    if public._queue_supplier_whatsapp(
         new.org_id, v_supplier.id, 'po_quote_request', 'po.quote_request',
         case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
         jsonb_build_object('request_id', v_request_id, 'item_type', new.item_type, 'item_id', new.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
         'purchase_quote_request', v_request_id
       ) = 'no_number' then
      v_unreachable := v_unreachable + 1;
    end if;
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — quote requests sent',
    format('Stock for this %s is at %s (min %s). Quote requests were sent to all known suppliers for %s units; the lowest logged reply (or last-known-cheapest if nobody replies) will be ordered automatically after %s hours.', new.item_type, new.stock_qty, new.min_stock, v_order_qty, v_timeout_hours)
      || case when v_unreachable > 0 then format(' %s supplier(s) have no valid WhatsApp number — ask them for a price by phone and log it in Purchase > Quotes.', v_unreachable) else '' end,
    new.id
  );

  return new;
end;
$$;

-- ── Monthly price check: active suppliers, gated sends ────────────────────
create or replace function public.open_monthly_quote_requests(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today_ist date := (now() at time zone 'Asia/Kolkata')::date;
  v_this_month text := to_char(v_today_ist, 'YYYY-MM');
  v_timeout_hours numeric(6, 2);
  v_item record;
  v_supplier record;
  v_order_qty integer;
  v_already_open boolean;
  v_request_id uuid;
  v_item_name text;
  v_rendered jsonb;
  v_body text;
  v_count integer := 0;
  v_inv_id uuid;
  v_inv_stock integer;
  v_inv_max integer;
begin
  update public.settings
  set po_quote_last_run_month = v_this_month
  where org_id = p_org_id
    and po_quote_day_of_month is not null
    and po_quote_day_of_month = extract(day from v_today_ist)::int
    and po_quote_last_run_month is distinct from v_this_month
  returning po_quote_timeout_hours into v_timeout_hours;

  if not found then
    return 0;
  end if;
  v_timeout_hours := coalesce(v_timeout_hours, 24);

  for v_item in
    select distinct sp.item_type, sp.item_id
    from public.supplier_products sp
    join public.suppliers s on s.id = sp.supplier_id and s.is_active
    where sp.org_id = p_org_id
  loop
    select exists (
      select 1 from public.po_items poi join public.purchase_orders po on po.id = poi.po_id
      where po.org_id = p_org_id and po.status in ('draft', 'sent')
        and poi.item_type = v_item.item_type and poi.item_id = v_item.item_id
    ) or exists (
      select 1 from public.purchase_quote_requests qr
      where qr.org_id = p_org_id and qr.status = 'open'
        and qr.item_type = v_item.item_type and qr.item_id = v_item.item_id
    ) into v_already_open;
    if v_already_open then
      continue;
    end if;

    select id, stock_qty, max_stock into v_inv_id, v_inv_stock, v_inv_max
    from public.inventory
    where org_id = p_org_id and item_type = v_item.item_type and item_id = v_item.item_id and location = 'warehouse';
    if v_inv_id is null then
      continue;
    end if;
    v_order_qty := greatest(1, v_inv_max - v_inv_stock);

    v_item_name := coalesce(public._wa_item_display_name(p_org_id, v_item.item_type, v_item.item_id), 'an item');

    insert into public.purchase_quote_requests (org_id, inventory_id, item_type, item_id, order_qty, status, requested_at, timeout_at)
    values (p_org_id, v_inv_id, v_item.item_type, v_item.item_id, v_order_qty, 'open', now(), now() + (v_timeout_hours * interval '1 hour'))
    returning id into v_request_id;

    for v_supplier in
      select s.id, s.name
      from public.supplier_products sp
      join public.suppliers s on s.id = sp.supplier_id and s.is_active
      where sp.org_id = p_org_id and sp.item_type = v_item.item_type and sp.item_id = v_item.item_id
    loop
      v_rendered := public._wa_render_template(
        p_org_id, 'po.quote_request',
        jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
      );
      v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
        else format('Hi %s, monthly price check - please reply with your current price for %s (qty: %s) and delivery time if possible. - GV Mart', v_supplier.name, v_item_name, v_order_qty)
      end;

      perform public._queue_supplier_whatsapp(
        p_org_id, v_supplier.id, 'po_quote_request', 'po.quote_request',
        case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
        jsonb_build_object('request_id', v_request_id, 'item_type', v_item.item_type, 'item_id', v_item.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
        'purchase_quote_request', v_request_id
      );
    end loop;

    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'monthly_rfq_sent', 'Monthly supplier price check sent',
      format('Quote requests were sent to every known supplier for %s item(s) as this month''s scheduled price check. Only items still at or below their minimum stock when replies resolve will actually be ordered — see Purchase > Quotes.', v_count),
      null
    );
  end if;

  return v_count;
end;
$$;

-- ── Bill entry / receipt ──────────────────────────────────────────────────
-- Now SECURITY DEFINER (was invoker) so it can raise the "received short" alert; every write is
-- scoped to p_org_id, which is checked against current_org_id() first, plus is_ops_staff().
create or replace function public.create_bill_entry(p_org_id uuid, p_supplier_id uuid, p_po_id uuid, p_items jsonb, p_gst numeric, p_bill_date date, p_bill_image_url text, p_category expense_category default 'purchase'::expense_category)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_subtotal numeric(12, 2) := 0;
  v_lines integer := 0;
  v_bill_id uuid;
  v_po public.purchase_orders;
  v_line_id uuid;
  v_short integer;
  v_supplier_name text;
  v_bill_date date := coalesce(p_bill_date, (now() at time zone 'Asia/Kolkata')::date);
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_bill_entry: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_bill_entry: caller is not ops staff';
  end if;
  select name into v_supplier_name from public.suppliers where id = p_supplier_id and org_id = p_org_id;
  if v_supplier_name is null then
    raise exception 'create_bill_entry: supplier not found';
  end if;
  if coalesce(p_gst, 0) < 0 then
    raise exception 'create_bill_entry: GST cannot be negative';
  end if;
  if p_bill_image_url is not null and p_bill_image_url not like p_org_id::text || '/%' then
    raise exception 'create_bill_entry: bill photo must be stored in your organisation''s folder';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'create_bill_entry: items must be a list';
  end if;

  -- validate every line before any side effect; a 0-qty line (nothing arrived) is skipped
  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty = 0 then
      continue;
    end if;
    perform public._validate_purchase_line('create_bill_entry', p_org_id, v_item.item_type, v_item.item_id, v_item.qty, v_item.price);
    v_lines := v_lines + 1;
  end loop;
  if v_lines = 0 then
    raise exception 'create_bill_entry: at least one item with a received quantity above zero is required';
  end if;

  -- Claim the PO before touching anything else: a second concurrent call (double-tap, or
  -- re-billing an already-received PO) finds 0 rows and is rejected before any side effect.
  if p_po_id is not null then
    update public.purchase_orders set status = 'received'
     where id = p_po_id and org_id = p_org_id and status = 'sent' and supplier_id = p_supplier_id
    returning * into v_po;
    if v_po.id is null then
      if exists (select 1 from public.purchase_orders where id = p_po_id and org_id = p_org_id and supplier_id is distinct from p_supplier_id) then
        raise exception 'create_bill_entry: purchase order % belongs to a different supplier', p_po_id;
      end if;
      raise exception 'create_bill_entry: purchase order % is not awaiting receipt (already received, cancelled, or not sent)', p_po_id;
    end if;
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x(item_type public.item_type, item_id uuid, qty integer, price numeric)
  loop
    if v_item.qty = 0 then
      continue;
    end if;
    v_subtotal := v_subtotal + (v_item.qty * v_item.price);

    update public.inventory
      set stock_qty = stock_qty + v_item.qty
      where org_id = p_org_id and item_type = v_item.item_type and item_id = v_item.item_id and location = 'warehouse';
    if not found then
      insert into public.inventory (org_id, item_type, item_id, stock_qty, location)
      values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty, 'warehouse');
    end if;

    insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
    values (p_org_id, v_item.item_type, v_item.item_id, v_item.qty, 'purchase_receipt', p_po_id);

    if v_item.item_type = 'product' then
      update public.products set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
    elsif v_item.item_type = 'spare' then
      update public.spares set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
    elsif v_item.item_type = 'gift' then
      update public.gifts set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
    end if;

    if p_po_id is not null then
      -- credit the first matching line that is still short
      select id into v_line_id from public.po_items
       where po_id = p_po_id and item_type = v_item.item_type and item_id = v_item.item_id
       order by (coalesce(received_qty, 0) >= qty), created_at
       limit 1;
      if v_line_id is not null then
        update public.po_items set received_qty = coalesce(received_qty, 0) + v_item.qty where id = v_line_id;
      end if;
    end if;
  end loop;

  if p_po_id is not null then
    select count(*) into v_short from public.po_items where po_id = p_po_id and coalesce(received_qty, 0) < qty;
    if v_short > 0 then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (p_org_id, 'operation_admin', 'po_received_short', 'Purchase order received short',
              format('%s line(s) on the purchase order from %s arrived short of the ordered quantity. Open Purchase > Orders to see what is missing and follow up with the supplier.', v_short, v_supplier_name),
              p_po_id);
    end if;
  end if;

  insert into public.purchase_bills (org_id, supplier_id, po_id, amount, gst, bill_image_url, bill_date)
  values (p_org_id, p_supplier_id, p_po_id, v_subtotal, coalesce(p_gst, 0), p_bill_image_url, v_bill_date)
  returning id into v_bill_id;

  insert into public.expenses (org_id, category, amount, ref_id, date)
  values (p_org_id, coalesce(p_category, 'purchase'), v_subtotal + coalesce(p_gst, 0), v_bill_id, v_bill_date);

  return v_bill_id;
end;
$$;

-- ── Payment, separate from delivery ───────────────────────────────────────
create or replace function public.mark_po_paid(p_po_id uuid)
returns purchase_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
begin
  if not public.is_master() then
    raise exception 'mark_po_paid: only master may mark a purchase order as paid';
  end if;

  update public.purchase_orders
    set paid_at = now(), paid_by = auth.uid()
    where id = p_po_id and org_id = public.current_org_id() and status in ('sent', 'received') and paid_at is null
    returning * into v_po;
  if v_po.id is null then
    raise exception 'mark_po_paid: purchase order % is not awaiting payment (already paid, still a draft, cancelled, or not found)', p_po_id;
  end if;

  update public.tasks
    set status = 'done'
    where ref_type = 'purchase_order' and ref_id = p_po_id and status = 'open';

  return v_po;
end;
$$;

create or replace function public.unmark_po_paid(p_po_id uuid)
returns purchase_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
begin
  if not public.is_master() then
    raise exception 'unmark_po_paid: only master may undo a payment';
  end if;

  update public.purchase_orders
    set paid_at = null, paid_by = null
    where id = p_po_id and org_id = public.current_org_id() and paid_at is not null
    returning * into v_po;
  if v_po.id is null then
    raise exception 'unmark_po_paid: purchase order % is not marked paid', p_po_id;
  end if;

  update public.tasks
    set status = 'open'
    where ref_type = 'purchase_order' and ref_id = p_po_id and status = 'done';

  return v_po;
end;
$$;

create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    -- a signed-in user who is not a master never marks a PO paid by ticking its task (the guard
    -- trigger already refuses the tick; this is the second, independent check).
    if auth.uid() is not null and not public.is_master() then
      return new;
    end if;
    update public.purchase_orders
      set paid_at = now(), paid_by = auth.uid()
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received') and paid_at is null;
  end if;
  return new;
end;
$$;

-- ── Bill photo storage ────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('purchase-bill-photos', 'purchase-bill-photos', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists purchase_bill_photos_storage_insert on storage.objects;
create policy purchase_bill_photos_storage_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'purchase-bill-photos'
              and (storage.foldername(name))[1] = public.current_org_id()::text
              and public.is_ops_staff());

drop policy if exists purchase_bill_photos_storage_select on storage.objects;
create policy purchase_bill_photos_storage_select on storage.objects
  for select to authenticated
  using (bucket_id = 'purchase-bill-photos'
         and (storage.foldername(name))[1] = public.current_org_id()::text
         and public.is_staff());

-- ── Grants ────────────────────────────────────────────────────────────────
-- Internal helpers / trigger functions: postgres + service_role only (same as the existing
-- _create_po_from_winning_quote / _auto_draft_purchase_order ACL).
revoke all on function public._normalize_in_mobile(text) from public, anon, authenticated;
revoke all on function public._queue_supplier_whatsapp(uuid, uuid, text, text, text, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function public._notify_po_not_messaged(uuid) from public, anon, authenticated;
revoke all on function public._send_po_to_supplier(uuid, text) from public, anon, authenticated;
revoke all on function public._validate_purchase_line(text, uuid, public.item_type, uuid, integer, numeric) from public, anon, authenticated;
revoke all on function public._cancel_po_on_approval_reject() from public, anon, authenticated;
grant execute on function public._normalize_in_mobile(text) to service_role;
grant execute on function public._queue_supplier_whatsapp(uuid, uuid, text, text, text, jsonb, text, uuid) to service_role;
grant execute on function public._notify_po_not_messaged(uuid) to service_role;
grant execute on function public._send_po_to_supplier(uuid, text) to service_role;
grant execute on function public._validate_purchase_line(text, uuid, public.item_type, uuid, integer, numeric) to service_role;
grant execute on function public._cancel_po_on_approval_reject() to service_role;

-- New staff RPC: authenticated (the function itself checks is_master()).
revoke all on function public.unmark_po_paid(uuid) from public, anon;
grant execute on function public.unmark_po_paid(uuid) to authenticated, service_role;
