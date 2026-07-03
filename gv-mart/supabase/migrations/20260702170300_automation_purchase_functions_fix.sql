-- Fix: repoint create_purchase_order / _auto_draft_purchase_order /
-- create_bill_entry at `po_items` (the real Phase 1 table) instead of the
-- accidental duplicate `purchase_order_items` dropped in
-- 20260702170200_fix_po_items_duplicate.sql. Function bodies are otherwise
-- unchanged from 20260702170100_automation_purchase_functions.sql.

create or replace function public.create_purchase_order(
  p_org_id uuid,
  p_supplier_id uuid,
  p_items jsonb
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
    insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
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
    from public.po_items poi
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

  insert into public.po_items (org_id, po_id, item_type, item_id, qty, price)
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

create or replace function public.create_bill_entry(
  p_org_id uuid,
  p_supplier_id uuid,
  p_po_id uuid,
  p_items jsonb,
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
