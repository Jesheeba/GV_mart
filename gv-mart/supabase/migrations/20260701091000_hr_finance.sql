-- HR / finance (BuildSpec §5 "HR / finance")
-- v2.2: no hardcoded incentive %/₹ or salary bands anywhere — every rate is
-- admin-set via these master/result tables (see supabase/seed: this
-- migration seeds no rows, seed data intentionally leaves rates for the
-- admin to configure in the Masters UI, Phase 4+).

create table incentive_rules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  type incentive_type not null,
  threshold numeric(12, 2) not null default 0,
  amount numeric(12, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index incentive_rules_org_id_idx on incentive_rules (org_id);

create table incentives_earned (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  rule_id uuid not null references incentive_rules (id) on delete restrict,
  amount numeric(12, 2) not null default 0 check (amount >= 0),
  period date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index incentives_earned_technician_id_idx on incentives_earned (technician_id);
create index incentives_earned_period_idx on incentives_earned (org_id, period);

create table rewards (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  category reward_category not null,
  period date not null,
  winner_id uuid references technicians (id) on delete set null,
  given_by uuid references profiles (id) on delete set null,
  given_at timestamptz not null default now(),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index rewards_org_id_idx on rewards (org_id);
create index rewards_winner_id_idx on rewards (winner_id);

create table salaries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  period date not null,
  base numeric(12, 2) not null default 0,
  revenue_component numeric(12, 2) not null default 0,
  late_deduction numeric(12, 2) not null default 0,
  incentives numeric(12, 2) not null default 0,
  net numeric(12, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index salaries_technician_period_idx on salaries (technician_id, period);
create index salaries_org_id_idx on salaries (org_id);

create table expenses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  category expense_category not null,
  amount numeric(12, 2) not null check (amount >= 0),
  ref_id uuid,
  date date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index expenses_org_id_idx on expenses (org_id);
create index expenses_category_idx on expenses (org_id, category);
