-- Technician ops (BuildSpec §5 "Technician ops")
-- v2.2 §6.8 tick order: Affirmation -> Pledge -> Meeting, locked after the
-- admin-editable late cutoff (settings.late_cutoff, default 09:15).

create table attendance (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  date date not null,
  check_in_at timestamptz,
  inside_geofence boolean not null default false,
  affirmation boolean not null default false,
  pledge boolean not null default false,
  meeting boolean not null default false,
  is_late boolean not null default false,
  selfie_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index attendance_technician_date_idx on attendance (technician_id, date);
create index attendance_org_id_idx on attendance (org_id);

create table spare_handovers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  date date not null,
  admin_sign_url text,
  tech_sign_url text,
  status text not null default 'pending' check (status in ('pending', 'confirmed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index spare_handovers_org_id_idx on spare_handovers (org_id);
create index spare_handovers_technician_id_idx on spare_handovers (technician_id);

create table spare_handover_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  handover_id uuid not null references spare_handovers (id) on delete cascade,
  spare_id uuid not null references spares (id) on delete restrict,
  qty_given integer not null default 0 check (qty_given >= 0),
  qty_returned integer not null default 0 check (qty_returned >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index spare_handover_items_handover_id_idx on spare_handover_items (handover_id);

-- Realtime location trail (ADM-15 / TECH-04 live tracking). Append-only.
create table technician_locations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  lat numeric(9, 6) not null,
  lng numeric(9, 6) not null,
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index technician_locations_technician_id_idx on technician_locations (technician_id, recorded_at desc);
