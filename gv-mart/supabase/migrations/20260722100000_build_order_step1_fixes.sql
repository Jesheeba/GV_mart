-- Build Order Step 1.3: bill-entry category tagging (Meeting spec F2's
-- prerequisite — "enforce category tagging at input time or filters return
-- empty"). create_bill_entry hardcoded every purchase bill's linked expense
-- to category='purchase' regardless of what was actually bought, unlike the
-- manual "Log Expense" panel (PnlReportTab.tsx) which already lets staff
-- pick from the real expense_category enum. Add the same choice here,
-- defaulting to 'purchase' (the common case for a supplier bill) but
-- overridable — same 7→8-arg overload-drop pattern already used elsewhere
-- in this codebase (create_quotation, create_sale) to avoid a stale
-- unreachable overload lingering in PostgREST's schema cache.

drop function if exists public.create_bill_entry(uuid, uuid, uuid, jsonb, numeric, date, text);

create or replace function public.create_bill_entry(
  p_org_id uuid,
  p_supplier_id uuid,
  p_po_id uuid,
  p_items jsonb,
  p_gst numeric,
  p_bill_date date,
  p_bill_image_url text,
  p_category expense_category default 'purchase'
)
returns uuid
language plpgsql
security invoker
as $$
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

  insert into public.purchase_bills (org_id, supplier_id, po_id, amount, gst, bill_image_url)
  values (p_org_id, p_supplier_id, p_po_id, v_subtotal, coalesce(p_gst, 0), p_bill_image_url)
  returning id into v_bill_id;

  insert into public.expenses (org_id, category, amount, ref_id, date)
  values (p_org_id, coalesce(p_category, 'purchase'), v_subtotal + coalesce(p_gst, 0), v_bill_id, coalesce(p_bill_date, current_date));

  if p_po_id is not null then
    update public.purchase_orders set status = 'received' where id = p_po_id and org_id = p_org_id;
  end if;

  return v_bill_id;
end;
$$;

grant execute on function public.create_bill_entry(uuid, uuid, uuid, jsonb, numeric, date, text, expense_category) to authenticated;
