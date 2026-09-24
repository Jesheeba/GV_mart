-- Fix: _create_po_payment_reminder_task's CASE expression for `priority`
-- resolved to text, not the priority_level enum the tasks.priority column
-- needs, causing "column \"priority\" is of type priority_level but
-- expression is of type text" on every call (caught by live verification
-- of 20260922100000_supplier_credit_terms_and_po_payment_reminder_tasks.sql
-- immediately after applying it). Body is otherwise unchanged from that
-- migration, just the explicit ::priority_level cast added.

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
