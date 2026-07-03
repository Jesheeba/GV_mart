-- Suppliers & purchase (BuildSpec §5 "Suppliers & purchase")

create table suppliers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  contact text,
  whatsapp text,
  rating numeric(2, 1) check (rating between 0 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index suppliers_org_id_idx on suppliers (org_id);

create table supplier_products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  supplier_id uuid not null references suppliers (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  price numeric(12, 2) not null check (price >= 0),
  lead_time_days integer check (lead_time_days >= 0),
  is_preferred boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index supplier_products_supplier_id_idx on supplier_products (supplier_id);
create index supplier_products_item_idx on supplier_products (org_id, item_type, item_id);

create table purchase_orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  supplier_id uuid not null references suppliers (id) on delete restrict,
  status po_status not null default 'draft',
  total numeric(12, 2) not null default 0 check (total >= 0),
  sent_channel text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index purchase_orders_org_id_idx on purchase_orders (org_id);
create index purchase_orders_supplier_id_idx on purchase_orders (supplier_id);

create table po_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  po_id uuid not null references purchase_orders (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  qty integer not null check (qty > 0),
  price numeric(12, 2) not null check (price >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index po_items_po_id_idx on po_items (po_id);

create table purchase_bills (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  supplier_id uuid not null references suppliers (id) on delete restrict,
  po_id uuid references purchase_orders (id) on delete set null,
  amount numeric(12, 2) not null check (amount >= 0),
  gst numeric(12, 2) not null default 0 check (gst >= 0),
  bill_image_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index purchase_bills_org_id_idx on purchase_bills (org_id);
create index purchase_bills_supplier_id_idx on purchase_bills (supplier_id);
