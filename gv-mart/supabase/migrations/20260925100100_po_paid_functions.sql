-- Money-flow-audit item 2 — PO -> expense reconciliation, step 2 of 2.
--
-- 1) Hard constraint, defense-in-depth beyond create_bill_entry's existing
--    status-flip guard (20260901130000_supplier_monthly_rfq_phase4.sql,
--    "update ... where status = 'sent'", checked via FOUND). That guard
--    only protects the one RPC's own call path — nothing at the schema
--    level stops a second purchase_bills row ever being inserted against
--    the same po_id by a different path. A partial unique index makes it
--    structurally impossible instead of merely application-enforced.
--    po_id is nullable (ad-hoc bills with no linked PO), so the index is
--    partial — any number of null-po_id bills stay unrestricted.
create unique index if not exists purchase_bills_po_id_unique_idx
  on public.purchase_bills (po_id) where po_id is not null;

-- 2) mark_po_paid — the one true "I paid this supplier" action. Master-only,
-- same gate as approve_purchase_order/the P&L report (financial settlement
-- decisions are master-scoped throughout this app). Claimable from 'sent'
-- OR 'received' — not received-only — because suppliers.credit_days = 0
-- ("immediate payment expected", per 20260922100000's own comment) can mean
-- paying at dispatch, before goods physically arrive; requiring 'received'
-- first would make that case un-recordable.
--
-- Also closes the linked payment-reminder task in the same call (a no-op
-- if none exists — legacy PO, or _create_po_payment_reminder_task's master-
-- lookup failed when it was created) so the two records can't drift apart
-- when payment is recorded from the PO side.
create or replace function public.mark_po_paid(p_po_id uuid)
returns public.purchase_orders
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
$$;

grant execute on function public.mark_po_paid(uuid) to authenticated;

-- 3) The reverse direction — completing the payment-reminder task from
-- TasksPage or WorkspacePage (both call the same generic setTaskStatus(),
-- a bare `tasks.update({status})` with no RPC/hook of its own) should carry
-- the same weight as clicking "Mark Paid" on the PO itself. A trigger is
-- the only place that guarantees this regardless of which of the two
-- screens completed the task. Idempotent — a PO that's already 'paid', or
-- one still 'draft', is silently left alone (mirrors mark_po_paid's own
-- guard, just without raising, since a background trigger has no UI to
-- surface an error to).
create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;

drop trigger if exists po_task_completed_marks_paid on public.tasks;
create trigger po_task_completed_marks_paid
  after update of status on public.tasks
  for each row
  execute function public._po_task_completed_marks_paid();
