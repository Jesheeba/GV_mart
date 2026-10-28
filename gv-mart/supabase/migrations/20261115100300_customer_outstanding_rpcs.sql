-- Accounts follow-up, Feature B, step 4 of 5 — create/reschedule/close/
-- cancel reminders, create a linked task, and the zero-outstanding
-- auto-close. All master-only SECURITY DEFINER, all RPC-only writes
-- (customer_outstanding_reminders/_links have no client write policy).
--
-- close_outstanding_reminders_if_zero is explicitly NOT a trigger on
-- invoices/sales/receipts/payments (owner's condition 2) — it is called
-- by the client after a payment succeeds, and opportunistically when the
-- Customer Outstanding detail view loads. It never touches `tasks`
-- (spec: never auto-complete a task).

create or replace function public.create_customer_outstanding_reminder(
  p_customer uuid, p_due_at timestamptz, p_note text default null, p_invoice uuid default null, p_amount numeric default 0
)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_reminder: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_reminder: customer not found in this organisation';
  end if;

  insert into public.customer_outstanding_reminders (org_id, customer_id, due_at, note)
  values (v_org, p_customer, p_due_at, p_note)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, reminder_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) to authenticated;

create or replace function public.reschedule_customer_outstanding_reminder(p_reminder uuid, p_due_at timestamptz, p_note text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'reschedule_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set due_at = p_due_at, note = coalesce(p_note, note)
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'reschedule_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) to authenticated;

create or replace function public.close_customer_outstanding_reminder(p_reminder uuid)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'done', closed_by = auth.uid(), closed_at = now()
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'close_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.close_customer_outstanding_reminder(uuid) from public, anon, authenticated;
grant execute on function public.close_customer_outstanding_reminder(uuid) to authenticated;

create or replace function public.cancel_customer_outstanding_reminder(p_reminder uuid, p_reason text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'cancel_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'cancelled', closed_by = auth.uid(), closed_at = now(), close_reason = p_reason
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'cancel_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.cancel_customer_outstanding_reminder(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_customer_outstanding_reminder(uuid, text) to authenticated;

-- Task side: reuses tasks.ref_type/ref_id (no new tasks columns). Master-
-- only write enforced a second, independent way by the trigger in the
-- next migration (_guard_customer_outstanding_task_ref), so this RPC's own
-- is_master() check is belt-and-suspenders, not the only gate.
create or replace function public.create_customer_outstanding_task(
  p_customer uuid, p_assignee uuid, p_title text, p_due_date date, p_invoice uuid default null, p_amount numeric default 0
)
returns public.tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.tasks;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_task: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_task: customer not found in this organisation';
  end if;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
  values (v_org, p_assignee, auth.uid(), p_title, p_due_date, 'manual', 'customer_outstanding', p_customer)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, task_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) to authenticated;

-- Zero-outstanding auto-close (owner's condition 2: computed on read / by
-- an RPC, never a trigger on a money table; does not touch tasks).
create or replace function public.close_outstanding_reminders_if_zero(p_customer uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero: master only';
  end if;

  select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
  from public.invoices i
  where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0;

  if v_outstanding > 0 then
    return 0;
  end if;

  with closed as (
    update public.customer_outstanding_reminders
      set status = 'done', source = 'system', closed_by = null, closed_at = now(),
          close_reason = 'outstanding reached zero'
      where org_id = v_org and customer_id = p_customer and status = 'open'
      returning 1
  )
  select count(*) into v_closed from closed;

  return v_closed;
end;
$$;
revoke all on function public.close_outstanding_reminders_if_zero(uuid) from public, anon, authenticated;
grant execute on function public.close_outstanding_reminders_if_zero(uuid) to authenticated;
