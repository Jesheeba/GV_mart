-- Catalog & inventory (BuildSpec §5 "Catalog & inventory")

create table brands (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  category brand_category not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index brands_org_id_idx on brands (org_id);

create table models (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  brand_id uuid not null references brands (id) on delete cascade,
  name text not null,
  type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index models_brand_id_idx on models (brand_id);

create table products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  brand_id uuid not null references brands (id) on delete restrict,
  model_id uuid not null references models (id) on delete restrict,
  name text not null,
  category brand_category not null,
  price numeric(12, 2) not null check (price >= 0),
  hsn_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index products_org_id_idx on products (org_id);
create index products_brand_model_idx on products (brand_id, model_id);

create table spares (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  sku text,
  price numeric(12, 2) not null check (price >= 0),
  hsn_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index spares_org_id_idx on spares (org_id);

-- v2.2 Design Deltas §A.1: minimum stock = 10, reorder qty = 10 (seed every
-- item 10/10 — see supabase/seed). `item_id` is polymorphic (product or
-- spare per `item_type`); Postgres has no cross-table FK, so referential
-- integrity for item_id is enforced in the services/ layer with Zod.
create table inventory (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  stock_qty integer not null default 0 check (stock_qty >= 0),
  min_stock integer not null default 10 check (min_stock >= 0),
  reorder_qty integer not null default 10 check (reorder_qty >= 0),
  location location_type not null default 'warehouse',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index inventory_org_id_idx on inventory (org_id);
create unique index inventory_item_location_idx on inventory (org_id, item_type, item_id, location);

create table inventory_movements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  change_qty integer not null,
  reason text not null,
  ref_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index inventory_movements_org_id_idx on inventory_movements (org_id);
create index inventory_movements_item_idx on inventory_movements (org_id, item_type, item_id);
