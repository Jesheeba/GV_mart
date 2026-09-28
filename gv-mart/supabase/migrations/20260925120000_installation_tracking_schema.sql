-- Technician Installation Tracking + Incentive — schema half.
--
-- Design decisions confirmed with the owner before building (see build
-- report): (1) an installation logs a SPECIFIC product as a new-install
-- pick, not a generic flag — so this needs its own row per product, not a
-- boolean on service_visits; (2) it's independent of ticket_type — a
-- technician can log an install on ANY visit (paid/warranty/amc/rental),
-- not only tickets that happen to carry ticket_type='installation' (that
-- enum value already exists for a different purpose: the create_sale
-- cart-level "sell + auto-schedule an install ticket" flow — seeeding
-- 20260804150000_referral_capture_functions.sql); (3) payout is a flat ₹
-- amount once a monthly count threshold is cleared, same shape as every
-- other incentive_rules type — no new payout mechanism needed.
--
-- Kept in its own file/transaction: this also adds a new incentive_type
-- enum value, and Postgres will not let a later statement in the same
-- transaction reference a brand-new enum label (precedent:
-- 20260723130000_finder_credit_schema.sql) — the compute_incentives branch
-- and technician_installation_count() that use 'installation' live in the
-- next migration.

create table public.installations_logged (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  visit_id uuid not null references public.service_visits (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete restrict,
  qty integer not null default 1 check (qty > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index installations_logged_org_id_idx on public.installations_logged (org_id);
create index installations_logged_technician_period_idx on public.installations_logged (technician_id, created_at);
create index installations_logged_visit_id_idx on public.installations_logged (visit_id);

alter table public.installations_logged enable row level security;

-- Written only by create_service_invoice (security definer, bypasses RLS —
-- same reasoning as service_spares_used/inventory_movements). Admin/staff
-- read for reporting; no direct technician or ops write policy needed.
create policy installations_logged_select_staff on public.installations_logged
  for select using (org_id = public.current_org_id() and public.is_staff());

create trigger audit_installations_logged after insert or update or delete on public.installations_logged
  for each row execute function public.audit_master_change();

-- New incentive type so an installation rule can sit in the same
-- admin-configurable incentive_rules master as service_income/sales_income/
-- review/finder_credit (Masters > Incentives) — no hardcoded ₹ rate here,
-- matching that table's "every rate is admin-set" convention. The owner
-- still needs to set threshold/amount for this rule via that screen.
alter type public.incentive_type add value if not exists 'installation';
