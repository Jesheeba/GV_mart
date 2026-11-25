-- Rollback for 20261213100000_vendor_flow_fixes.sql. Function bodies below are the live
-- definitions read on 2026-11-25 before the migration. The po_status value cancelled cannot be
-- dropped (Postgres has no DROP VALUE); any PO set to cancelled is put back to draft first.
-- Run in ONE transaction.

update public.purchase_orders set status = 'draft' where status = 'cancelled';
update public.purchase_orders set status = 'paid' where paid_at is not null;

drop trigger if exists approvals_reject_cancels_po on public.approvals;
drop function if exists public._cancel_po_on_approval_reject();
drop function if exists public.unmark_po_paid(uuid);

CREATE OR REPLACE FUNCTION public._auto_draft_purchase_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
begin
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
    select 1 from public.supplier_products
    where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id
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

  -- One row per invited supplier, each with its own rendered/fallback body
  -- — this is what wa-milestone-dispatch now finds and pushes through
  -- sendMessage() (Blocker 0 fix; see that function's MILESTONE_REF_TYPES).
  for v_supplier in
    select s.id, s.whatsapp, s.name
    from public.supplier_products sp
    join public.suppliers s on s.id = sp.supplier_id
    where sp.org_id = new.org_id and sp.item_type = new.item_type and sp.item_id = new.item_id
  loop
    if v_supplier.whatsapp is null then
      -- Nothing to dispatch to. The purchase_quote_requests row and the
      -- admin notification below still cover this item; skip creating a
      -- phantom outbox row with a null destination.
      continue;
    end if;

    v_rendered := public._wa_render_template(
      new.org_id, 'po.quote_request',
      jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
    );
    -- Deliberately deviates from the customer milestone triggers (which
    -- leave payload.body empty when no whatsapp_templates row exists): no
    -- migration has ever seeded ANY milestone template (checked
    -- supabase/seed/seed.ts), so relying solely on _wa_render_template
    -- would leave this path silently non-functional the same way Blocker 0
    -- was. An admin can still override the wording later via Automation >
    -- Templates (row name "po.quote_request") with no code change.
    v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
      else format('Hi %s, we need a quote for %s (qty: %s). Please reply with your price per unit (and delivery time if possible). - GV Mart', v_supplier.name, v_item_name, v_order_qty)
    end;

    insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, type, payload, ref_type, ref_id, status)
    values (
      new.org_id, 'outbound', v_supplier.whatsapp, 'po_quote_request', 'po.quote_request',
      case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
      jsonb_build_object('request_id', v_request_id, 'item_type', new.item_type, 'item_id', new.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
      'purchase_quote_request', v_request_id, 'sent'
    );
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'low_stock', 'Stock critical — quote requests sent',
    format('Stock for this %s is at %s (min %s). Quote requests were sent to all known suppliers for %s units; the lowest logged reply (or last-known-cheapest if nobody replies) will be ordered automatically after %s hours.', new.item_type, new.stock_qty, new.min_stock, v_order_qty, v_timeout_hours),
    new.id
  );

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public._create_po_from_winning_quote(p_org_id uuid, p_item_type item_type, p_item_id uuid, p_order_qty integer, p_supplier_id uuid, p_price numeric, p_inventory_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po_id uuid;
  v_total numeric(12, 2);
  v_threshold numeric(12, 2);
  v_requires_approval boolean;
begin
  select po_approval_threshold, po_requires_approval into v_threshold, v_requires_approval
  from public.settings where org_id = p_org_id;
  v_total := coalesce(p_price, 0) * p_order_qty;

  if v_requires_approval then
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

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  values (p_org_id, 'outbound', (select whatsapp from public.suppliers where id = p_supplier_id), 'po_sent', 'po.auto_sent',
          jsonb_build_object('po_id', v_po_id, 'total', v_total, 'item_type', p_item_type, 'item_id', p_item_id),
          'purchase_order', v_po_id, 'sent');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'low_stock', 'Quote resolved — PO auto-drafted',
    format('A supplier quote was resolved and a purchase order for %s units was auto-drafted and sent.', p_order_qty),
    p_inventory_id
  );

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    select p_org_id, 'po', v_po_id, id, 'pending' from public.profiles where org_id = p_org_id and role = 'master' limit 1;
  end if;

  return v_po_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public._po_task_completed_marks_paid()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    -- a signed-in user who is not a master never marks a PO paid by ticking its task (the guard above already refuses the tick;
    -- this is the second, independent check). No signed-in user = service role / scheduled job: unchanged.
    if auth.uid() is not null and not public.is_master() then
      return new;
    end if;
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public._resolve_purchase_quote_requests_core(p_org_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    select r.supplier_id, r.price into v_best_supplier, v_best_price
    from public.purchase_quote_replies r
    where r.request_id = v_req.id
    order by r.price asc, r.logged_at asc
    limit 1;

    if v_best_supplier is not null then
      v_resolution := 'reply';
    else
      select supplier_id, price into v_best_supplier, v_best_price
      from public.supplier_products
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id
      order by is_preferred desc, price asc
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
        format('Quote requests for this %s timed out with no replies, and no supplier is linked to it anymore. Order manually.', v_req.item_type),
        v_req.inventory_id
      );
    else
      -- NEW: only actually place an order if the item is still at/below its
      -- minimum stock right now — a monthly price-refresh request (opened
      -- for every supplier-linked item, not just low-stock ones) should
      -- record the winning price for comparison without auto-ordering
      -- something that was never actually short. Scoped to the warehouse
      -- location, matching where supplier reordering happens (vans are
      -- restocked from the warehouse, not ordered from suppliers directly).
      select stock_qty, min_stock into v_stock_qty, v_min_stock
      from public.inventory
      where org_id = v_req.org_id and item_type = v_req.item_type and item_id = v_req.item_id and location = 'warehouse';

      if v_stock_qty is not null and v_stock_qty > v_min_stock then
        update public.purchase_quote_requests
        set status = 'resolved', resolved_at = now(), resolution = 'no_po_not_low_stock', updated_at = now()
        where id = v_req.id;
        -- Deliberately no notification here — this is the expected, routine
        -- outcome for most items on a monthly batch, not an alert-worthy
        -- event. The winning price is still visible in the Quotes tab's
        -- resolved list and already landed in supplier_products via
        -- wa_log_quote_reply/log_purchase_quote_reply's price write-back.
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
$function$;

CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_approval_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  select v_po.org_id, 'outbound', s.whatsapp, 'po_sent', 'po.approved_and_sent',
         jsonb_build_object('po_id', v_po.id, 'total', v_po.total), 'purchase_order', v_po.id, 'sent'
  from public.suppliers s where s.id = v_po.supplier_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    v_po.org_id, 'operation_admin', 'low_stock', 'Approved PO sent',
    format('Purchase order %s (₹%s) was approved and sent to the supplier.', v_po.id, v_po.total), v_po.id
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_bill_entry(p_org_id uuid, p_supplier_id uuid, p_po_id uuid, p_items jsonb, p_gst numeric, p_bill_date date, p_bill_image_url text, p_category expense_category DEFAULT 'purchase'::expense_category)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_item record;
  v_subtotal numeric(12, 2) := 0;
  v_bill_id uuid;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_bill_entry: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_bill_entry: caller is not ops staff';
  end if;

  -- Claim the PO before touching anything else â€” a second concurrent call
  -- (double-tap, or re-billing an already-received PO) finds 0 rows here
  -- and is rejected before any inventory/expense side effect runs.
  if p_po_id is not null then
    update public.purchase_orders set status = 'received' where id = p_po_id and org_id = p_org_id and status = 'sent';
    if not found then
      raise exception 'create_bill_entry: purchase order % is not awaiting receipt (already received, or not sent)', p_po_id;
    end if;
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

    if v_item.price is not null then
      if v_item.item_type = 'product' then
        update public.products set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      elsif v_item.item_type = 'spare' then
        update public.spares set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      elsif v_item.item_type = 'gift' then
        update public.gifts set cost_price = v_item.price where id = v_item.item_id and org_id = p_org_id;
      end if;
    end if;
  end loop;

  insert into public.purchase_bills (org_id, supplier_id, po_id, amount, gst, bill_image_url)
  values (p_org_id, p_supplier_id, p_po_id, v_subtotal, coalesce(p_gst, 0), p_bill_image_url)
  returning id into v_bill_id;

  insert into public.expenses (org_id, category, amount, ref_id, date)
  values (p_org_id, coalesce(p_category, 'purchase'), v_subtotal + coalesce(p_gst, 0), v_bill_id, coalesce(p_bill_date, (now() at time zone 'Asia/Kolkata')::date));

  return v_bill_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_purchase_order(p_org_id uuid, p_supplier_id uuid, p_items jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
    values (p_org_id, v_po_id, v_item.item_type, v_item.item_id, v_item.qty, coalesce(v_item.price, 0));
    v_total := v_total + (v_item.qty * coalesce(v_item.price, 0));
  end loop;

  update public.purchase_orders set total = v_total, status = 'sent' where id = v_po_id;

  perform public._create_po_payment_reminder_task(v_po_id);

  -- a supplier with no usable WhatsApp number used to get a number-less outbox row (never sent); keep the PO
  -- working in that case instead of failing the whole order on the checked door's number validation
  if length(regexp_replace(coalesce((select whatsapp from public.suppliers where id = p_supplier_id), ''), '[^0-9]', '', 'g')) >= 10 then
    perform public.send_staff_whatsapp(
      p_org_id, (select whatsapp from public.suppliers where id = p_supplier_id), null,
      'po_sent', 'po.sent', jsonb_build_object('po_id', v_po_id, 'total', v_total), 'purchase_order', v_po_id
    );
  end if;

  if v_threshold is not null and v_total > v_threshold then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'po', v_po_id, auth.uid(), 'pending');
  end if;

  return v_po_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.mark_po_paid(p_po_id uuid)
 RETURNS purchase_orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_po public.purchase_orders;
begin
  if not public.is_master() then
    raise exception 'mark_po_paid: only master may mark a purchase order as paid';
  end if;

  update public.purchase_orders
    set status = 'paid'
    where id = p_po_id and org_id = public.current_org_id() and status in ('sent', 'received')
    returning * into v_po;
  if v_po.id is null then
    raise exception 'mark_po_paid: purchase order % is not awaiting payment (already paid, still draft, or not found)', p_po_id;
  end if;

  update public.tasks
    set status = 'done'
    where ref_type = 'purchase_order' and ref_id = p_po_id and status = 'open';

  return v_po;
end;
$function$;

CREATE OR REPLACE FUNCTION public.open_monthly_quote_requests(p_org_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- Atomic claim: the WHERE clause is the entire concurrency guard (same
  -- state-flip-as-lock idiom as approve_purchase_order) — if today isn't
  -- the configured day, or this month already ran, the UPDATE matches zero
  -- rows and we return immediately. Two overlapping invocations for the
  -- same org can't both pass this and open two batches for the month.
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
    where sp.org_id = p_org_id
  loop
    -- Same "already covered" guard as the reactive trigger — don't
    -- duplicate a reorder that's already in flight for this item.
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

    -- Only an item actually tracked in the warehouse can be quoted for —
    -- same basis _auto_draft_purchase_order uses for order_qty.
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
      select s.id, s.whatsapp, s.name
      from public.supplier_products sp
      join public.suppliers s on s.id = sp.supplier_id
      where sp.org_id = p_org_id and sp.item_type = v_item.item_type and sp.item_id = v_item.item_id
    loop
      if v_supplier.whatsapp is null then
        continue;
      end if;

      v_rendered := public._wa_render_template(
        p_org_id, 'po.quote_request',
        jsonb_build_object('supplier_name', v_supplier.name, 'item_name', v_item_name, 'order_qty', v_order_qty::text)
      );
      v_body := case when (v_rendered ->> 'found')::boolean then v_rendered ->> 'body'
        else format('Hi %s, monthly price check - please reply with your current price for %s (qty: %s) and delivery time if possible. - GV Mart', v_supplier.name, v_item_name, v_order_qty)
      end;

      insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, type, payload, ref_type, ref_id, status)
      values (
        p_org_id, 'outbound', v_supplier.whatsapp, 'po_quote_request', 'po.quote_request',
        case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
        jsonb_build_object('request_id', v_request_id, 'item_type', v_item.item_type, 'item_id', v_item.item_id, 'order_qty', v_order_qty, 'supplier_id', v_supplier.id, 'body', v_body),
        'purchase_quote_request', v_request_id, 'sent'
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
$function$;

CREATE OR REPLACE FUNCTION public.update_po_items_and_approve(p_approval_id uuid, p_items jsonb DEFAULT '[]'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, milestone, template, payload, ref_type, ref_id, status)
  select v_po.org_id, 'outbound', s.whatsapp, 'po_sent', 'po.approved_and_sent',
         jsonb_build_object('po_id', v_po.id, 'total', v_po.total), 'purchase_order', v_po.id, 'sent'
  from public.suppliers s where s.id = v_po.supplier_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    v_po.org_id, 'operation_admin', 'low_stock', 'Approved PO sent',
    format('Purchase order %s (₹%s) was approved and sent to the supplier.', v_po.id, v_po.total), v_po.id
  );
end;
$function$;

drop function if exists public._send_po_to_supplier(uuid, text);
drop function if exists public._notify_po_not_messaged(uuid);
drop function if exists public._queue_supplier_whatsapp(uuid, uuid, text, text, text, jsonb, text, uuid);
drop function if exists public._validate_purchase_line(text, uuid, public.item_type, uuid, integer, numeric);
drop function if exists public._normalize_in_mobile(text);

drop policy if exists purchase_bill_photos_storage_insert on storage.objects;
drop policy if exists purchase_bill_photos_storage_select on storage.objects;
-- the purchase-bill-photos bucket is left in place (it may hold uploaded bills).

drop index if exists public.supplier_products_supplier_item_uq;
alter table public.suppliers drop column if exists is_active;
alter table public.purchase_bills drop column if exists bill_date;
alter table public.po_items drop column if exists received_qty;
alter table public.purchase_orders drop column if exists paid_by;
alter table public.purchase_orders drop column if exists paid_at;
