-- Rollback for held/20261015100000_whatsapp_outbound_gate.sql (F-08). Restores the previous (open) state.
-- NOTE: only roll back if the gate breaks a legitimate sender; the open state lets any active staff queue a message to any number.

-- create_purchase_order: the exact pre-change body (calls the unchecked stub)
create or replace function public.create_purchase_order(p_org_id uuid, p_supplier_id uuid, p_items jsonb)
returns uuid
language plpgsql
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

  perform public._create_po_payment_reminder_task(v_po_id);

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

grant execute on function public.send_whatsapp_stub(uuid, text, uuid, text, text, jsonb, text, uuid) to public, anon, authenticated;
drop function if exists public.send_staff_whatsapp(uuid, text, uuid, text, text, jsonb, text, uuid);

grant insert, update, delete, truncate on public.whatsapp_outbox to anon, authenticated;
create policy whatsapp_outbox_insert_staff on public.whatsapp_outbox for insert
  with check (org_id = public.current_org_id() and public.is_staff());

drop trigger if exists settings_wa_test_guard on public.settings;
drop function if exists public._trg_settings_wa_test_guard();
alter table public.settings drop constraint if exists settings_wa_test_numbers_valid;
alter table public.settings drop column if exists wa_test_allowed_numbers, drop column if exists wa_test_mode_enabled;
drop function if exists public._wa_numbers_valid(text[]);
alter table public.whatsapp_outbox drop column if exists sent_by;
