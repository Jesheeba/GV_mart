-- Supplier Monthly RFQ pipeline — Phase 3: PO approval red popup with
-- editable quantities. Builds on Phases 1-2.
--
-- Two real gaps found while building this, both addressed here:
--   1. approvals RLS was master-only for SELECT (approvals_select_master) —
--      operation_admin had zero visibility into a pending PO approval, even
--      read-only. The approved design ("both master and operation_admin can
--      view the popup, only master can act") needs operation_admin to be
--      able to see it. Widened narrowly: an ADDITIONAL permissive policy
--      scoped to type='po' only (every other approval type — discount,
--      price_override, leave — stays master-only, unchanged), gated on
--      is_ops_staff() (master OR operation_admin, exactly the two roles
--      asked for — not is_staff(), which would also include sales_admin).
--   2. No RPC existed to edit po_items quantities before approval —
--      approve_purchase_order only ever flips status on the PO as drafted.
--      update_po_items_and_approve below is a superset of it: same guards,
--      same dispatch, plus an up-front quantity-edit step.

create policy approvals_select_po_ops on public.approvals
  for select using (org_id = public.current_org_id() and type = 'po' and public.is_ops_staff());

-- ── update_po_items_and_approve ───────────────────────────────────────────
-- p_items: jsonb array of {"id": "<po_items.id>", "qty": <integer>}. Only
-- items belonging to the resolved PO can ever be touched (the UPDATE below
-- is scoped by po_id AND org_id), so a caller can't smuggle in an edit to
-- an unrelated order.
--
-- Ordering matters for the double-tap/concurrent-approval guard: the
-- approvals status flip happens FIRST, before any quantity edit is applied
-- — that single atomic UPDATE...WHERE is what approve_purchase_order already
-- uses as its race guard, and doing it first here means only the ONE caller
-- who actually wins that race ever gets to edit quantities or dispatch
-- anything. (Applying edits before claiming the approval would let two
-- concurrent callers each write different quantities before either's
-- approval attempt was actually settled.)
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

  -- Claim the approval FIRST (see header comment) — same guard shape as
  -- approve_purchase_order: only a caller whose UPDATE actually matches a
  -- still-'pending' row proceeds past this point.
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
$$;

grant execute on function public.update_po_items_and_approve(uuid, jsonb) to authenticated;

-- ── Realtime trigger for the new modal ────────────────────────────────────
-- _create_po_from_winning_quote's approval-gated branch already inserts a
-- 'low_stock'-typed notification (unchanged, still feeds the bell/
-- Notifications page as before). This ADDS a second, purpose-built
-- notification type the new PoApprovalPromptModal subscribes to — one row
-- per role so both master and operation_admin get their own realtime
-- INSERT to react to (notifications.role is a single value, not an array).
create or replace function public._create_po_from_winning_quote(
  p_org_id uuid,
  p_item_type public.item_type,
  p_item_id uuid,
  p_order_qty integer,
  p_supplier_id uuid,
  p_price numeric,
  p_inventory_id uuid
)
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
$$;
