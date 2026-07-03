-- Leads & automation (BuildSpec §5 "Leads & automation")

create table leads (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid references customers (id) on delete set null,
  name text not null,
  mobile text,
  source lead_source not null default 'other',
  enquiry_type enquiry_type,
  status lead_status not null default 'new',
  owner_id uuid references technicians (id) on delete set null,
  score integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index leads_org_id_idx on leads (org_id);
create index leads_status_idx on leads (org_id, status);
create index leads_owner_id_idx on leads (owner_id);

-- Resolves the quotations <-> leads circular reference (quotations was
-- created before leads existed).
alter table quotations
  add column lead_id uuid references leads (id) on delete set null,
  add constraint quotations_customer_or_lead check (customer_id is not null or lead_id is not null);

create table lead_activities (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  lead_id uuid not null references leads (id) on delete cascade,
  type text not null,
  note text,
  at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index lead_activities_lead_id_idx on lead_activities (lead_id);

create table automation_flows (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  trigger enquiry_type not null,
  action automation_action not null,
  asset_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index automation_flows_org_id_idx on automation_flows (org_id);

create table video_library (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  topic enquiry_type not null,
  url text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index video_library_org_id_idx on video_library (org_id);

-- v2.2 §6.8 / Design Deltas #44: per-point value is admin-set (min 50, see
-- settings.referral_point_value) — no fixed "1 pt = ₹1" conversion here.
create table referral_points (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  customer_id uuid not null references customers (id) on delete cascade,
  points integer not null,
  reason text,
  ref_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index referral_points_customer_id_idx on referral_points (customer_id);
