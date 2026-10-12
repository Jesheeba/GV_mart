-- Review (phase 0, 2026-10-12): ten SECURITY DEFINER functions that WRITE data had no internal guard and were executable by
-- PUBLIC (hence anon: the public key plus an organisation id was enough). Their only real callers are other definer
-- functions (which run as the owner) and service-role Edge Functions (wa-scheduled-tasks); no pg_cron job and no browser code
-- calls them. EXECUTE is now limited to service_role (and the owner).
--
-- create_purchase_order is SECURITY INVOKER and called _create_po_payment_reminder_task as the signed-in user, which this
-- revoke would break. It is made SECURITY DEFINER (search_path = public); its own guards are unchanged and run first:
-- organisation match and is_ops_staff(). Behaviour is otherwise identical (still audited, still sends through
-- send_staff_whatsapp).
--
-- Previous ACLs are saved in Desktop\GV_mart_acl_backup_2026-10-12_unguarded_write_functions.json and in
-- supabase/rollbacks/20261015120000_revoke_unguarded_write_functions.rollback.sql.

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
$$;

-- Every overload of each function is handled by name, so a signature change cannot leave one open.
do $rev$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('_auto_assign_ticket_internal', '_sale_create_line_invoice', '_create_po_payment_reminder_task',
                         '_resolve_purchase_quote_requests_core', 'wa_resolve_purchase_quote_requests',
                         'advance_recurring_tasks', 'open_monthly_quote_requests', 'run_rental_billing',
                         'wa_escalate_overdue_po_payment_reminders', '_create_po_from_winning_quote')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$rev$;
