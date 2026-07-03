-- System (BuildSpec §5 "System")
--
-- Deviation from the BuildSpec draft: `settings` is modelled as one typed
-- row per org (not a generic key/value table), and `organizations.settings
-- jsonb` from the identity section is dropped — this table is the single
-- source of truth for the operational parameters instead of having two
-- places to look. Every default below is the v2.2-mandated value (Design
-- Deltas §A); nothing here is a fixed business figure the client didn't
-- sign off on — all remain admin-editable via the future Masters/Settings
-- screen (ADM-30).
create table settings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique references organizations (id) on delete cascade,
  -- v2.2 §6.6: "1 km = 5 minutes" — admin-set standard for the distance-reach indicator.
  per_km_minutes numeric(5, 2) not null default 5 check (per_km_minutes > 0),
  -- v2.2 §6.8: geofenced attendance, "inside office only" — no distance
  -- figure is ever shown to the technician; this radius is only the
  -- internal boundary used to compute "inside".
  geofence_radius_m integer not null default 150 check (geofence_radius_m > 0),
  -- v2.2 §6.4: working time 9:00 AM to 7:30 PM.
  work_start time not null default '09:00',
  work_end time not null default '19:30',
  -- v2.2 §6.8: attendance/meeting/affirmation/pledge locked after 9:15 (admin-editable).
  late_cutoff time not null default '09:15',
  -- v2.2 §6.5: lunch 30 min allowed; over 45 min shows red.
  lunch_minutes_allowed integer not null default 30 check (lunch_minutes_allowed > 0),
  lunch_minutes_red_threshold integer not null default 45 check (lunch_minutes_red_threshold > lunch_minutes_allowed),
  -- v2.2 §6.1: technician up to 5%, admin up to 10%, above 10% never allowed.
  discount_tech_max numeric(5, 2) not null default 5 check (discount_tech_max >= 0 and discount_tech_max <= 100),
  discount_admin_max numeric(5, 2) not null default 10 check (discount_admin_max >= discount_tech_max and discount_admin_max <= 100),
  -- v2.2 §6.7: AMC self-booking only when the renewal date is near; admin sets how many days before.
  amc_book_window_days integer not null default 15 check (amc_book_window_days > 0),
  -- v2.2 §6.8: value per referral point is admin-set, minimum 50 — no fixed "1 pt = ₹1".
  referral_point_value numeric(12, 2) not null default 50 check (referral_point_value >= 50),
  -- v2.2 §6.7: Google review link shows only at 4.5 or 5 stars.
  review_link_min_stars numeric(2, 1) not null default 4.5 check (review_link_min_stars >= 1 and review_link_min_stars <= 5),
  -- v2.2 §6.10: minimum stock 10, reorder qty 10 — defaults for newly-added inventory rows.
  default_min_stock integer not null default 10 check (default_min_stock >= 0),
  default_reorder_qty integer not null default 10 check (default_reorder_qty >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table approvals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  type approval_type not null,
  ref_id uuid not null,
  requested_by uuid not null references profiles (id) on delete restrict,
  status approval_status not null default 'pending',
  approver_id uuid references profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index approvals_org_id_idx on approvals (org_id);
create index approvals_status_idx on approvals (org_id, status);

-- `user_id` targets one person; `role` broadcasts to everyone with that
-- role in the org. Exactly one of the two is set.
create table notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  user_id uuid references profiles (id) on delete cascade,
  role user_role,
  type text not null,
  title text not null,
  body text,
  is_read boolean not null default false,
  ref_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notifications_user_or_role check (
    (user_id is not null and role is null) or (user_id is null and role is not null)
  )
);

create index notifications_org_id_idx on notifications (org_id);
create index notifications_user_id_idx on notifications (user_id) where user_id is not null;
create index notifications_role_idx on notifications (org_id, role) where role is not null;

create table audit_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  actor_id uuid references profiles (id) on delete set null,
  action text not null,
  table_name text not null,
  row_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index audit_log_org_id_idx on audit_log (org_id, created_at desc);
create index audit_log_table_row_idx on audit_log (table_name, row_id);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  assignee_id uuid references profiles (id) on delete set null,
  title text not null,
  due_date date,
  status task_status not null default 'open',
  source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index tasks_org_id_idx on tasks (org_id);
create index tasks_assignee_id_idx on tasks (assignee_id);
