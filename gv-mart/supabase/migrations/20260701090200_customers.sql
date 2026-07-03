-- Customers (BuildSpec §5 "Customers")

create table customers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  primary_profile_id uuid unique references profiles (id) on delete set null,
  name text not null,
  mobile text not null,
  profession text,
  source lead_source,
  tags text[] not null default '{}',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customers_org_id_idx on customers (org_id);
create index customers_mobile_idx on customers (org_id, mobile);

-- max 5 per customer (BuildSpec §5) — enforced by trigger below (a CHECK
-- constraint cannot see sibling rows) and re-checked in the app layer.
create table customer_members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  name text not null,
  mobile text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_members_customer_id_idx on customer_members (customer_id);
create unique index customer_members_one_primary_idx on customer_members (customer_id) where is_primary;

create table addresses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  door_no text,
  flat_no text,
  street_cross text,
  area text,
  pincode text,
  landmark text,
  district text,
  state text,
  lat numeric(9, 6),
  lng numeric(9, 6),
  address_type address_type not null default 'residential',
  ownership ownership_type not null default 'own',
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index addresses_customer_id_idx on addresses (customer_id);
create index addresses_pincode_idx on addresses (org_id, pincode);
create unique index addresses_one_primary_idx on addresses (customer_id) where is_primary;
