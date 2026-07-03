-- AMC & warranty (BuildSpec §5 "AMC & warranty")
-- v2.2 §6.2: "AMC plans are sold only on RO products" — enforced in the
-- services/ layer (Zod + RPC), not a DB CHECK, since Postgres CHECK
-- constraints cannot reference another table's rows.

create table amc_plans (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  years integer not null check (years > 0),
  price numeric(12, 2) not null check (price >= 0),
  inclusions jsonb not null default '[]'::jsonb,
  gift_id uuid references gifts (id) on delete set null,
  visits_per_year integer not null default 4 check (visits_per_year > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index amc_plans_org_id_idx on amc_plans (org_id);

create table amc_contracts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  product_id uuid not null references products (id) on delete restrict,
  plan_id uuid not null references amc_plans (id) on delete restrict,
  start_date date not null,
  expiry_date date not null,
  status amc_status not null default 'active',
  next_service_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint amc_contracts_dates_order check (expiry_date > start_date)
);

create index amc_contracts_org_id_idx on amc_contracts (org_id);
create index amc_contracts_customer_id_idx on amc_contracts (customer_id);
create index amc_contracts_status_idx on amc_contracts (org_id, status);

create table warranties (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  product_id uuid not null references products (id) on delete restrict,
  serial_no text,
  start_date date not null,
  expiry_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint warranties_dates_order check (expiry_date > start_date)
);

create index warranties_org_id_idx on warranties (org_id);
create index warranties_customer_id_idx on warranties (customer_id);
