-- Sales (BuildSpec §5 "Sales")
-- `leads` is created later (Leads & automation migration); quotations/leads
-- have a circular relationship (quotation <-> lead) so the lead_id FK here
-- is added via ALTER TABLE in the leads migration once `leads` exists.

create table quotations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid references customers (id) on delete cascade,
  status quotation_status not null default 'open',
  valid_until date,
  total numeric(12, 2) not null default 0 check (total >= 0),
  lost_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index quotations_org_id_idx on quotations (org_id);
create index quotations_customer_id_idx on quotations (customer_id);

create table quotation_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  quotation_id uuid not null references quotations (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  qty integer not null check (qty > 0),
  price numeric(12, 2) not null check (price >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index quotation_items_quotation_id_idx on quotation_items (quotation_id);

-- gifts is a master (BuildSpec §5); threshold_amount lives here, not in
-- `settings`, so there is a single source of truth per gift.
create table gifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  threshold_amount numeric(12, 2) not null check (threshold_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index gifts_org_id_idx on gifts (org_id);

-- `payment_description` added beyond the BuildSpec draft: v2.2 §6.1
-- requires "the transaction or ID and a short description" for bank
-- transfer — the description field was missing from the original column list.
create table invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete restrict,
  type invoice_type not null,
  subtotal numeric(12, 2) not null default 0 check (subtotal >= 0),
  discount numeric(12, 2) not null default 0 check (discount >= 0),
  gst numeric(12, 2) not null default 0 check (gst >= 0),
  total numeric(12, 2) not null default 0 check (total >= 0),
  payment_method payment_method,
  txn_id text,
  payment_description text,
  payment_status payment_status not null default 'due',
  gift_id uuid references gifts (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint invoices_transfer_requires_txn check (
    payment_method is distinct from 'transfer'
    or (txn_id is not null and payment_description is not null)
  )
);

create index invoices_org_id_idx on invoices (org_id);
create index invoices_customer_id_idx on invoices (customer_id);

create table invoice_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  invoice_id uuid not null references invoices (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  qty integer not null check (qty > 0),
  price numeric(12, 2) not null check (price >= 0),
  discount numeric(12, 2) not null default 0 check (discount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index invoice_items_invoice_id_idx on invoice_items (invoice_id);

create table gift_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  invoice_id uuid not null references invoices (id) on delete cascade,
  gift_id uuid not null references gifts (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index gift_logs_invoice_id_idx on gift_logs (invoice_id);
