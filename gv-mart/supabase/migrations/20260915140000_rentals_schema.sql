-- Item D5: "Rent" service type. Schema only — RPCs, billing cron, and UI
-- follow in separate commits (see session notes for the full design:
-- rental_plans/rental_contracts mirror amc_plans/amc_contracts; a rental has
-- no fixed term so visits are scheduled one at a time via
-- create_service_invoice's completion hook, not pre-computed like AMC's
-- fixed-duration loop; billing is a new daily cron RPC since neither AMC
-- nor EMI has any recurring-charge mechanism to reuse).

create type public.rental_status as enum ('active', 'returned');

alter type public.ticket_type add value if not exists 'rental';
alter type public.invoice_type add value if not exists 'rent';

-- Admin-configurable rental plans (master-only), mirrors amc_plans — no
-- `years`/expiry concept, since a rental runs until the unit is returned,
-- not for a fixed term.
create table public.rental_plans (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  monthly_rate numeric(12, 2) not null check (monthly_rate >= 0),
  visits_per_year integer not null default 4 check (visits_per_year > 0),
  inclusions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index rental_plans_org_id_idx on public.rental_plans (org_id);

create table public.rental_contracts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete restrict,
  plan_id uuid not null references public.rental_plans (id) on delete restrict,
  address_id uuid references public.addresses (id) on delete set null,
  start_date date not null,
  status public.rental_status not null default 'active',
  next_billing_date date,
  next_service_date date,
  returned_at timestamptz,
  invoice_id uuid references public.invoices (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index rental_contracts_org_id_idx on public.rental_contracts (org_id);
create index rental_contracts_customer_id_idx on public.rental_contracts (customer_id);
create index rental_contracts_status_idx on public.rental_contracts (org_id, status);
-- Billing cron's own hot path: "every active contract due today or earlier".
create index rental_contracts_billing_idx on public.rental_contracts (next_billing_date) where status = 'active';

-- Traces a rental visit ticket back to the contract that scheduled it —
-- same purpose as service_tickets.contract_id (AMC) / warranty_id.
alter table public.service_tickets
  add column rental_contract_id uuid references public.rental_contracts (id) on delete set null;

create index service_tickets_rental_contract_id_idx on public.service_tickets (rental_contract_id);

alter table public.rental_plans enable row level security;
alter table public.rental_contracts enable row level security;

-- Same shape as the AMC policies (20260701091300_rls.sql): plans are
-- catalog data any org member can read but only master can write; contracts
-- are visible to staff org-wide and to the customer's own login, written by
-- ops/sales (the roles that already sell AMC and process returns/visits).
create policy rental_plans_select_org on public.rental_plans for select using (org_id = public.current_org_id());
create policy rental_plans_write_master on public.rental_plans for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy rental_contracts_select_staff on public.rental_contracts
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy rental_contracts_select_own on public.rental_contracts
  for select using (customer_id = public.current_customer_id());
create policy rental_contracts_write_ops_sales on public.rental_contracts for all
  using (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()))
  with check (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()));
