-- Supplier Monthly RFQ pipeline — Phase 4: receipt-confirmation red popup,
-- admin-gated inventory increase. Builds on Phases 1-3.
--
-- Real gap found and fixed here (same "critical fixes" discipline as
-- Phase 3): create_bill_entry's `update purchase_orders set status =
-- 'received' where id = p_po_id and org_id = p_org_id` had NO status
-- guard — two concurrent calls (a double-tap, or the same PO billed twice
-- by mistake) would both pass, each fully re-running the inventory
-- increment + inventory_movements + expense insert. Fixed by claiming the
-- PO FIRST (`... and status = 'sent'`, checked via FOUND) before any
-- inventory/expense side effect runs — same state-flip-as-lock ordering
-- used for update_po_items_and_approve in Phase 3. Body is otherwise
-- byte-for-byte the live version from 20260730100000_cost_price_tracking_
-- functions.sql (cost-price snapshot included) — signature unchanged, so
-- BillEntryTab.tsx's existing manual flow keeps working exactly as before.
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

  -- Claim the PO before touching anything else — a second concurrent call
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
  values (p_org_id, coalesce(p_category, 'purchase'), v_subtotal + coalesce(p_gst, 0), v_bill_id, coalesce(p_bill_date, current_date));

  return v_bill_id;
end;
$$;

-- Grant unchanged (already authenticated, is_ops_staff()-gated inside) — this is a create-or-replace on the same signature.

-- ── wa_supplier_latest_sent_po ────────────────────────────────────────────
-- Deterministic "did it arrive" trigger, per the approved design: no
-- attempt to classify what the supplier's reply actually says (dispatch
-- vs. delivery vs. anything else) — any reply while a PO is outstanding is
-- treated as a signal to ask the admin. Service-role only, called from
-- handleSupplierReply when there's no open quote request for this
-- supplier (the RFQ-reply path already handles that case).
create or replace function public.wa_supplier_latest_sent_po(p_org_id uuid, p_supplier_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.purchase_orders
  where org_id = p_org_id and supplier_id = p_supplier_id and status = 'sent'
  order by created_at desc
  limit 1;
$$;

-- Intentionally NOT granted to authenticated — service_role only.

-- ── One more real gap found while wiring the receipt-check popup ─────────
-- (A second one — notifications' role-broadcast UPDATE/mark-read RLS — was
-- suspected but turned out to already be fixed by
-- 20260804190000_fix_notifications_mark_read_rls.sql, which also lets
-- master mark ANY role's broadcast row read, not just their own — exactly
-- what PoReceiptPromptModal needs to clear both roles' copies of a prompt
-- when a master resolves it. Checked the live DB before assuming a gap.)
--
-- purchase_orders was never added to the supabase_realtime publication.
-- PoReceiptPromptModal needs to react to a PO's status flipping to
-- 'received' (from ANY source — another admin's device, or even the
-- pre-existing manual Bill Entry flow) so both viewers' copies of the
-- popup close themselves, not just the one that clicked Confirm.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'purchase_orders'
  ) then
    alter publication supabase_realtime add table purchase_orders;
  end if;
end $$;
