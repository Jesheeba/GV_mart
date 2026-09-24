-- Supplier payment terms + auto payment-reminder tasks on PO send.
--
-- Requirement 1: suppliers.credit_days — plain integer, not an enum. 0 =
-- "immediate payment expected"; any positive number = "Net N days". Matches
-- every other supplier-side numeric field (rating, supplier_products.
-- lead_time_days) already being a plain number with a 0/null convention.
--
-- Requirement 2: every purchase order that transitions to status='sent'
-- gets exactly one payment-reminder task auto-created in the just-built
-- Tasks system (20260921160000_task_assignment_system.sql), always assigned
-- to master, due_at = sent time + supplier.credit_days, priority reusing
-- priority_level (credit_days <= 7 -> urgent, else normal). assigned_by is
-- left null (system-generated, not self-assigned, not the PO approver) so
-- the existing _notify_task_assigned trigger fires the task_assigned
-- notification normally — it only skips when assigned_by = assignee_id.
--
-- There are exactly 4 live call sites that flip a purchase_orders row to
-- 'sent' (verified by reading every migration that touches purchase_orders.
-- status): create_purchase_order (manual admin create), the immediate-send
-- branch of _create_po_from_winning_quote (auto-drafted, po_requires_
-- approval off), approve_purchase_order (generic Approvals page), and
-- update_po_items_and_approve (PoApprovalPromptModal, editable qty). Each
-- is create-or-replaced below with its existing body unchanged plus one new
-- call to _create_po_payment_reminder_task at the point it flips to 'sent'.
-- (_auto_draft_purchase_order is NOT a hook point — 20260725120000_po_
-- quotation_first_with_timeout_safeguard.sql already reversed it to only
-- open a quote request; it never creates a PO directly any more.)
--
-- Requirement 3: a one-shot overdue escalation, 3 days past due_at, piggy-
-- backing the existing daily wa-scheduled-tasks pass (shouldRunJob/
-- markJobRan, already admin-configurable, already the pattern for AMC
-- reminders/monthly RFQ/rental billing) instead of a new cron workflow —
-- this function has already had one CRON_SECRET mismatch outage, so reusing
-- its one existing trigger surface instead of adding a second is deliberate.
-- escalated_at is a one-shot marker, same idiom as whatsapp_outbox.
-- retried_at, so a task is escalated at most once, not renagged daily.

alter table public.suppliers
  add column if not exists credit_days integer not null default 0;

alter table public.suppliers
  add constraint suppliers_credit_days_check check (credit_days >= 0);

alter table public.tasks
  add column if not exists escalated_at timestamptz;

-- ── Requirement 2: reminder-task helper ───────────────────────────────────
create or replace function public._create_po_payment_reminder_task(p_po_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po record;
  v_master_id uuid;
begin
  if exists (select 1 from public.tasks where ref_type = 'purchase_order' and ref_id = p_po_id) then
    return;
  end if;

  select po.org_id, po.total, s.name as supplier_name, s.credit_days
    into v_po
    from public.purchase_orders po
    join public.suppliers s on s.id = po.supplier_id
    where po.id = p_po_id;

  if v_po is null then
    return;
  end if;

  select id into v_master_id from public.profiles where org_id = v_po.org_id and role = 'master' limit 1;
  if v_master_id is null then
    return;
  end if;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, description, priority, due_at, ref_type, ref_id)
  values (
    v_po.org_id,
    v_master_id,
    null,
    format('Pay %s for PO %s', v_po.supplier_name, p_po_id),
    format('₹%s due — %s', v_po.total, case when v_po.credit_days = 0 then 'immediate payment' else format('Net %s days', v_po.credit_days) end),
    (case when v_po.credit_days <= 7 then 'urgent' else 'normal' end)::priority_level,
    now() + (v_po.credit_days || ' days')::interval,
    'purchase_order',
    p_po_id
  );
end;
$$;

-- ── Requirement 2: hook the 4 live sent-transitions ───────────────────────

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
$$;

-- ── Requirement 3: one-shot overdue escalation, called from the existing
-- daily wa-scheduled-tasks pass (see supabase/functions/wa-scheduled-tasks/
-- index.ts) rather than a new cron surface ──────────────────────────────
create or replace function public.wa_escalate_overdue_po_payment_reminders(p_org_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task record;
  v_count int := 0;
begin
  for v_task in
    update public.tasks
    set escalated_at = now()
    where org_id = p_org_id
      and ref_type = 'purchase_order'
      and status = 'open'
      and due_at is not null
      and due_at < now() - interval '3 days'
      and escalated_at is null
    returning *
  loop
    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (
      v_task.org_id, v_task.assignee_id, 'task_overdue', 'Payment reminder overdue',
      format('"%s" was due %s and is still open.', v_task.title, to_char(v_task.due_at, 'DD Mon YYYY')),
      v_task.id
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.wa_escalate_overdue_po_payment_reminders(uuid) to service_role;
