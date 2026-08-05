-- QR Payment + Gated Completion Code — append-only audit log of payment
-- events. Distinct from invoices.payment_status/amount_paid (the rolled-up
-- current state, already existing per 20260805090000_invoice_amount_paid_
-- schema.sql): this is a per-event record of who confirmed what, when.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  -- Nullable: every row this phase is visit-scoped (UPI collected on-site
  -- during OnSiteVisitPage's Payment step), but a counter/admin sale
  -- invoice (create_sale) has no visit at all — leaving this nullable now
  -- avoids a schema change later if that path ever records payments here too.
  visit_id uuid references public.service_visits (id) on delete set null,
  amount numeric(12, 2) not null check (amount >= 0),
  payment_method payment_method not null,
  -- Reserved for a future payment-gateway transaction id (Razorpay/Cashfree/
  -- etc.) — no gateway is integrated this phase, always null today.
  gateway_reference text,
  -- Reuses the existing payment_status enum rather than inventing a new
  -- one. This phase only ever inserts 'paid' rows (manual technician
  -- confirmation is all-or-nothing).
  payment_status payment_status not null default 'paid',
  paid_at timestamptz not null default now(),
  confirmed_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
-- No updated_at/set_updated_at trigger — an append-only log, rows are never
-- mutated after insert.

create index payments_org_id_idx on public.payments (org_id);
create index payments_invoice_id_idx on public.payments (invoice_id);

alter table public.payments enable row level security;

-- Staff read for financial oversight — no technician or customer policy at
-- all, matching service_visit_otps' posture: every technician interaction
-- goes through record_upi_payment (SECURITY DEFINER) below, never a direct
-- table read or write.
create policy payments_select_staff on public.payments
  for select using (org_id = public.current_org_id() and public.is_staff());

-- No insert/update/delete policy for any client role on purpose — every
-- write happens inside record_upi_payment, which performs its own
-- authorization checks before writing.
