-- Amount tracking fix, Phase 0 (schema only, no behavior change).
--
-- `invoices.payment_status` has been hardcoded to 'paid' at every insert
-- site since the column was introduced (20260701090500_sales.sql) — nothing
-- in the whole migration history ever runs `update invoices set
-- payment_status`. The enum + UI (PaymentStatusBadge, dashboards, customer
-- booking detail) are correctly built; only the data feeding them is wrong.
-- payment_status alone also can't represent *how much* of a partial payment
-- was collected, so this adds a real amount_paid column alongside it.
--
-- This migration only adds the column and a shared derivation helper.
-- Nothing writes to amount_paid yet — that starts in the next migration
-- (20260805100000_invoice_payment_rpcs.sql), which also fixes the
-- hardcoded-'paid' RPCs.

alter table public.invoices
  add column if not exists amount_paid numeric(12, 2) not null default 0 check (amount_paid >= 0);

-- Every existing invoice was created with payment_status hardcoded to
-- 'paid', so backfill those (and only those) to stay internally consistent.
update public.invoices
  set amount_paid = total
  where payment_status = 'paid';

-- Shared across every invoice-creating function so the paid/partial/due
-- boundary logic (and its edge cases — zero-total invoices, exact
-- equality) is defined once instead of six times.
create or replace function public._derive_payment_status(p_amount_paid numeric, p_total numeric)
returns payment_status
language sql
immutable
as $$
  select case
    when p_total <= 0 or p_amount_paid >= p_total then 'paid'::payment_status
    when p_amount_paid <= 0 then 'due'::payment_status
    else 'partial'::payment_status
  end
$$;
