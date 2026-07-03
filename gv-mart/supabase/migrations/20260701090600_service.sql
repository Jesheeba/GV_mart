-- Service (BuildSpec §5 "Service")

create table service_tickets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  address_id uuid references addresses (id) on delete set null,
  product_id uuid references products (id) on delete set null,
  brand_id uuid references brands (id) on delete set null,
  model_id uuid references models (id) on delete set null,
  name_of_complaint text,
  nature_of_complaint text,
  type ticket_type,
  priority priority_level not null default 'normal',
  status ticket_status not null default 'open',
  channel ticket_channel not null default 'call',
  sla_due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_tickets_org_id_idx on service_tickets (org_id);
create index service_tickets_customer_id_idx on service_tickets (customer_id);
create index service_tickets_status_idx on service_tickets (org_id, status);

-- v2.2 §6.4: "One person cannot have two open appointments at once."
-- Enforced with a partial unique index — one active (scheduled/in_progress)
-- appointment per technician at a time.
create table appointments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  ticket_id uuid not null references service_tickets (id) on delete cascade,
  technician_id uuid references technicians (id) on delete set null,
  scheduled_at timestamptz,
  mode appointment_mode not null default 'datetime',
  status appointment_status not null default 'scheduled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index appointments_org_id_idx on appointments (org_id);
create index appointments_ticket_id_idx on appointments (ticket_id);
create index appointments_technician_id_idx on appointments (technician_id);
create unique index appointments_one_open_per_technician_idx
  on appointments (technician_id)
  where status in ('scheduled', 'in_progress') and technician_id is not null;

create table service_visits (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  ticket_id uuid not null references service_tickets (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete restrict,
  timer_start timestamptz,
  timer_end timestamptz,
  before_image_url text,
  after_image_url text,
  service_charge numeric(12, 2) not null default 0 check (service_charge >= 0),
  discount numeric(5, 2) not null default 0 check (discount >= 0 and discount <= 100),
  otp_verified boolean not null default false,
  needs_revisit boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_visits_org_id_idx on service_visits (org_id);
create index service_visits_ticket_id_idx on service_visits (ticket_id);
create index service_visits_technician_id_idx on service_visits (technician_id);

create table service_sop_steps (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  visit_id uuid not null references service_visits (id) on delete cascade,
  step_name text not null,
  expected_minutes integer not null check (expected_minutes > 0),
  done_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_sop_steps_visit_id_idx on service_sop_steps (visit_id);

create table service_spares_used (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  visit_id uuid not null references service_visits (id) on delete cascade,
  spare_id uuid not null references spares (id) on delete restrict,
  qty integer not null check (qty > 0),
  cost numeric(12, 2) not null default 0 check (cost >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_spares_used_visit_id_idx on service_spares_used (visit_id);

create table ro_checklists (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  visit_id uuid not null unique references service_visits (id) on delete cascade,
  tds_before numeric(6, 2),
  tds_after numeric(6, 2),
  tank_cleaned boolean,
  product_explained boolean,
  client_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- `stars` is numeric, not integer: v2.2 §6.7 gates the Google review link at
-- "4.5 or 5" specifically, so half-star ratings must be representable.
create table ratings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  visit_id uuid not null unique references service_visits (id) on delete cascade,
  stars numeric(2, 1) not null check (stars >= 1 and stars <= 5),
  review text,
  google_review_clicked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index ratings_org_id_idx on ratings (org_id);
