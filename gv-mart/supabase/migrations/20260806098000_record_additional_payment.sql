-- Partial-payment gap fix: none of the invoice-creating RPCs (create_sale,
-- create_service_invoice, sell_amc_plan_onsite) had any way to top up an
-- invoice that was left "partial"/"due" — record_upi_payment only handles
-- UPI and always jumps straight to the full total. Sales staff had no path
-- in the app to record a follow-up cash/transfer/upi collection, so any
-- partial invoice stayed partial forever short of a manual DB edit.
--
-- Writes to the existing append-only public.payments audit table
-- (20260806092000_payments_table.sql), which was already schema'd to be
-- method-agnostic and to allow a null visit_id for exactly this kind of
-- non-visit, admin-side collection.
create or replace function public.record_additional_payment(
  p_org_id uuid,
  p_invoice_id uuid,
  p_amount numeric,
  p_payment_method payment_method,
  p_txn_id text default null,
  p_payment_description text default null
)
returns invoices
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice invoices;
  v_new_amount_paid numeric(12, 2);
begin
  if not public.is_sales_staff() then
    raise exception 'record_additional_payment: only master or sales_admin may record a payment';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'record_additional_payment: org mismatch';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'record_additional_payment: amount must be positive';
  end if;
  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'record_additional_payment: bank transfer requires a transaction ID and description';
  end if;

  select * into v_invoice from public.invoices where id = p_invoice_id and org_id = p_org_id for update;
  if v_invoice.id is null then
    raise exception 'record_additional_payment: invoice % not found in org %', p_invoice_id, p_org_id;
  end if;

  v_new_amount_paid := v_invoice.amount_paid + p_amount;
  if v_new_amount_paid > v_invoice.total then
    raise exception 'record_additional_payment: amount (%) exceeds the remaining balance of %', p_amount, v_invoice.total - v_invoice.amount_paid;
  end if;

  update public.invoices
    set amount_paid = v_new_amount_paid,
        payment_status = public._derive_payment_status(v_new_amount_paid, total)
    where id = p_invoice_id
    returning * into v_invoice;

  insert into public.payments (org_id, invoice_id, amount, payment_method, payment_status, confirmed_by)
  values (p_org_id, p_invoice_id, p_amount, p_payment_method, 'paid', auth.uid());

  return v_invoice;
end;
$$;

grant execute on function public.record_additional_payment(uuid, uuid, numeric, payment_method, text, text) to authenticated;
