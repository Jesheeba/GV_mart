-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 1/8.
-- Master-configured product lifetime + spare-part replacement schedule.
-- Kept as separate tables (not new columns on products) so the master-only
-- write guard is isolated, matching the precedent set by products.item_code's
-- own guard migration (20261104120000_item_code_master_update_guard.sql).

create table public.product_lifecycle_configs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  lifetime_value integer not null check (lifetime_value > 0),
  lifetime_unit text not null check (lifetime_unit in ('months', 'years')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id)
);

create index product_lifecycle_configs_org_id_idx on public.product_lifecycle_configs (org_id);

create table public.product_spare_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  spare_id uuid references public.spares (id) on delete set null,
  label text not null,
  interval_value integer not null check (interval_value > 0),
  interval_unit text not null check (interval_unit in ('months', 'years')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_spare_schedules_product_id_idx
  on public.product_spare_schedules (product_id) where is_active;
create index product_spare_schedules_org_id_idx on public.product_spare_schedules (org_id);

create trigger set_updated_at before update on public.product_lifecycle_configs
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.product_spare_schedules
  for each row execute function public.set_updated_at();

-- Config changes are master-table edits like any other Masters screen edit —
-- reuse the existing generic audit trigger rather than inventing a bespoke log.
create trigger audit_product_lifecycle_configs after insert or update or delete
  on public.product_lifecycle_configs for each row execute function public.audit_master_change();
create trigger audit_product_spare_schedules after insert or update or delete
  on public.product_spare_schedules for each row execute function public.audit_master_change();

alter table public.product_lifecycle_configs enable row level security;
alter table public.product_spare_schedules enable row level security;

create policy product_lifecycle_configs_select_staff on public.product_lifecycle_configs
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy product_lifecycle_configs_write_master on public.product_lifecycle_configs
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy product_spare_schedules_select_staff on public.product_spare_schedules
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy product_spare_schedules_write_master on public.product_spare_schedules
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

-- Close the known default-privileges leak (new tables/sequences otherwise
-- auto-grant to anon on this project — see memory: default_privileges_anon_execute_leak).
revoke all on public.product_lifecycle_configs from public, anon;
revoke all on public.product_spare_schedules from public, anon;
grant select, insert, update, delete on public.product_lifecycle_configs to authenticated;
grant select, insert, update, delete on public.product_spare_schedules to authenticated;
