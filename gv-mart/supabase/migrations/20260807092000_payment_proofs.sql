-- Enhancement spec Task 2 — UPI Payment Proof Upload. After the technician
-- confirms a UPI payment (record_upi_payment, 20260806093000_upi_payment_
-- gating.sql), they upload a screenshot/photo of the payment confirmation;
-- this stores it permanently, linked to the customer/ticket/visit/
-- technician/invoice/payment record all at once, for the admin Customer
-- History / Booking Details audit trail.
--
-- Same "private bucket + SECURITY DEFINER-only write" posture as
-- ticket-photos (20260804170000_gate_assignment_on_product.sql) and
-- `payments` itself (20260806092000_payments_table.sql) — no direct client
-- insert/update/delete policy on the table; every write goes through
-- record_payment_proof below, which performs its own authorization checks.
-- No delete policy anywhere (table or bucket): proofs are permanent.

create table public.payment_proofs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  payment_id uuid not null references public.payments (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  visit_id uuid references public.service_visits (id) on delete set null,
  ticket_id uuid references public.service_tickets (id) on delete set null,
  customer_id uuid not null references public.customers (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  storage_path text not null,
  transaction_reference text,
  uploaded_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index payment_proofs_org_id_idx on public.payment_proofs (org_id);
create index payment_proofs_invoice_id_idx on public.payment_proofs (invoice_id);
create index payment_proofs_payment_id_idx on public.payment_proofs (payment_id);

alter table public.payment_proofs enable row level security;

create policy payment_proofs_select_staff on public.payment_proofs
  for select using (org_id = public.current_org_id() and public.is_staff());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy payment_proofs_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'payment-proofs' and public.current_technician_id() is not null
);
create policy payment_proofs_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'payment-proofs' and public.is_staff()
);

-- ── record_payment_proof: technician-uploaded proof, resolved server-side ──
-- Only the storage path is trusted from the client (the upload itself
-- already went through the bucket's own insert policy above); everything
-- else this row links to (payment/invoice/ticket/customer) is resolved
-- server-side from the visit, the same "never trust client-supplied
-- identity" posture as record_upi_payment/verify_visit_otp.
create or replace function public.record_payment_proof(
  p_org_id uuid,
  p_visit_id uuid,
  p_storage_path text,
  p_transaction_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_invoice invoices;
  v_payment payments;
  v_proof payment_proofs;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'record_payment_proof: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'record_payment_proof: org mismatch';
  end if;
  if nullif(btrim(p_storage_path), '') is null then
    raise exception 'record_payment_proof: storage_path is required';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'record_payment_proof: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'record_payment_proof: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket.id is null then
    raise exception 'record_payment_proof: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_invoice from public.invoices where id = v_ticket.invoice_id and org_id = p_org_id;
  if v_invoice.id is null then
    -- Same shape as record_upi_payment's invoice_pending: the offline
    -- outbox hasn't synced the invoice yet — the frontend surfaces this as
    -- "still syncing, try again shortly" rather than a generic failure.
    raise exception 'record_payment_proof: invoice_pending — invoice for visit % has not synced yet', p_visit_id;
  end if;

  select * into v_payment from public.payments
  where invoice_id = v_invoice.id and payment_method = 'upi'
  order by created_at desc
  limit 1;
  if v_payment.id is null then
    raise exception 'record_payment_proof: payment_missing — confirm the UPI payment before uploading proof for visit %', p_visit_id;
  end if;

  insert into public.payment_proofs (
    org_id, payment_id, invoice_id, visit_id, ticket_id, customer_id, technician_id, storage_path, transaction_reference
  ) values (
    p_org_id, v_payment.id, v_invoice.id, p_visit_id, v_ticket.id, v_ticket.customer_id, v_tech_id,
    p_storage_path, nullif(btrim(p_transaction_reference), '')
  ) returning * into v_proof;

  return jsonb_build_object('ok', true, 'id', v_proof.id);
end;
$$;

grant execute on function public.record_payment_proof(uuid, uuid, text, text) to authenticated;
