-- Identity & org (BuildSpec §5 "Identity & org")

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  gst_no text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- profiles.id === auth.users.id (1:1), per BuildSpec §5 "links auth.users"
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  org_id uuid not null references organizations (id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null,
  photo_url text,
  language text not null default 'en' check (language in ('en', 'ta')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index profiles_org_id_idx on profiles (org_id);
create index profiles_role_idx on profiles (role);

-- Note: `zone` (present in an earlier internal draft of technicians) is
-- deliberately dropped — the v2.2 Design Deltas explicitly list "Zone/Area
-- Master" under "DO NOT ADD" and ADM-14 only lists zone under ENHANCE, not
-- APPEARS. Not in the signed v2.2 scope.
create table technicians (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  profile_id uuid not null unique references profiles (id) on delete cascade,
  skills text[] not null default '{}',
  is_on_duty boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index technicians_org_id_idx on technicians (org_id);
