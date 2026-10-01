-- Technician salary tiers + promotion eligibility (design approved 2026-10-01).
-- Schema + backfill only; compute_salary, detection and approve/dismiss RPCs
-- follow in separate migrations.

create table public.technician_tiers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  rank int not null check (rank >= 1),
  monthly_salary numeric(12, 2) not null default 0 check (monthly_salary >= 0),
  -- Promotion INTO this tier: paid revenue needed within required_months.
  -- Null on the entry tier (nothing to be promoted from).
  required_earning numeric(12, 2) check (required_earning is null or required_earning >= 0),
  required_months int check (required_months is null or required_months >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, rank)
);

create index technician_tiers_org_id_idx on public.technician_tiers (org_id);

alter table public.technicians
  add column tier_id uuid references public.technician_tiers (id) on delete restrict;

create index technicians_tier_id_idx on public.technicians (tier_id);

-- Seed an entry tier per org so every technician has somewhere to land.
-- monthly_salary = 0 on purpose: compute_salary's base moves from "attributed
-- revenue" to "tier salary", and revenue_component takes over the old
-- calculation, so with a 0 entry-tier salary every technician's net pay is
-- identical to what it is today until master sets real tier salaries.
insert into public.technician_tiers (org_id, name, rank, monthly_salary)
select o.id, 'Tier 1', 1, 0 from public.organizations o
on conflict (org_id, rank) do nothing;

update public.technicians t
set tier_id = tt.id
from public.technician_tiers tt
where tt.org_id = t.org_id and tt.rank = 1 and t.tier_id is null;

create table public.tier_promotion_eligibility (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  target_tier_id uuid not null references public.technician_tiers (id) on delete cascade,
  earning_snapshot numeric(12, 2) not null,
  window_months int not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'dismissed')),
  detected_at timestamptz not null default now(),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The design sketched unique (technician_id, target_tier_id, status), but its
-- stated intent is "blocks duplicate PENDING rows only, master can re-flag
-- later" — a full unique on status would reject a second dismissal (or a
-- second approval after a demotion) of the same pair. A partial unique index
-- implements the intent exactly.
create unique index tier_promotion_eligibility_one_pending_idx
  on public.tier_promotion_eligibility (technician_id, target_tier_id)
  where status = 'pending';
create index tier_promotion_eligibility_org_status_idx
  on public.tier_promotion_eligibility (org_id, status);

create table public.tier_promotion_history (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  old_tier_id uuid references public.technician_tiers (id) on delete set null,
  new_tier_id uuid not null references public.technician_tiers (id) on delete cascade,
  approved_by uuid not null references public.profiles (id),
  promoted_at timestamptz not null default now()
);

create index tier_promotion_history_technician_idx on public.tier_promotion_history (technician_id);

create trigger set_updated_at before update on public.technician_tiers
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.tier_promotion_eligibility
  for each row execute function public.set_updated_at();

alter table public.technician_tiers enable row level security;
alter table public.tier_promotion_eligibility enable row level security;
alter table public.tier_promotion_history enable row level security;

-- Tiers: master-only writes. Read is staff (salary figures are sensitive —
-- a technician login must not see other tiers' pay).
create policy technician_tiers_select_staff on public.technician_tiers
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy technician_tiers_write_master on public.technician_tiers for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

-- Eligibility / history: master reads; all writes go through the
-- security-definer approve/dismiss RPCs and the service-role detector.
create policy tier_promotion_eligibility_select_master on public.tier_promotion_eligibility
  for select using (org_id = public.current_org_id() and public.is_master());
create policy tier_promotion_history_select_master on public.tier_promotion_history
  for select using (org_id = public.current_org_id() and public.is_master());

grant select, insert, update, delete on public.technician_tiers to authenticated;
grant select on public.tier_promotion_eligibility to authenticated;
grant select on public.tier_promotion_history to authenticated;
-- This project's default privileges auto-grant to anon; strip it.
revoke all on public.technician_tiers, public.tier_promotion_eligibility, public.tier_promotion_history from anon;
