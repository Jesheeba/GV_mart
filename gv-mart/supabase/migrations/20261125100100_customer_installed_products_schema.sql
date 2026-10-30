-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 2/8.
-- The per-customer per-unit asset record this stack has never had (the gap
-- explicitly deferred in 20261104100000_product_item_code.sql's own header).

create table public.customer_installed_products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  product_id uuid not null references public.products (id),
  installation_date date not null,
  -- Amendment: the schedule must run off the REAL installation date. Until a
  -- technician/master confirms it, installation_date defaults from the
  -- invoice/visit date it was backfilled or created from, and is shown to the
  -- Master as corrigible, not authoritative. installation_date_confirmed
  -- flips true once a human has explicitly set/confirmed it via
  -- correct_installation_date().
  installation_date_confirmed boolean not null default false,
  installation_visit_id uuid references public.service_visits (id),
  lifecycle_config_id uuid references public.product_lifecycle_configs (id),
  lifetime_expiry_date date,
  status text not null default 'active' check (status in ('active', 'expired', 'removed')),
  is_backfilled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_installed_products_customer_id_idx
  on public.customer_installed_products (customer_id);
create index customer_installed_products_org_expiry_idx
  on public.customer_installed_products (org_id, lifetime_expiry_date) where status = 'active';

create table public.customer_part_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  installed_product_id uuid not null references public.customer_installed_products (id) on delete cascade,
  product_spare_schedule_id uuid not null references public.product_spare_schedules (id),
  label text not null,
  interval_value integer not null check (interval_value > 0),
  interval_unit text not null check (interval_unit in ('months', 'years')),
  last_replaced_date date,
  next_due_date date not null,
  status text not null default 'pending'
    check (status in ('pending', 'due_soon', 'due', 'overdue', 'replaced_na')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (installed_product_id, product_spare_schedule_id)
);

create index customer_part_schedules_org_due_idx
  on public.customer_part_schedules (org_id, next_due_date) where status <> 'replaced_na';
create index customer_part_schedules_installed_product_idx
  on public.customer_part_schedules (installed_product_id);

create trigger set_updated_at before update on public.customer_installed_products
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.customer_part_schedules
  for each row execute function public.set_updated_at();

-- Generic audit trigger doubles as the audit record amendment #1 asked for:
-- every installation_date correction is a plain UPDATE on this table, so its
-- before/after (including installation_date_confirmed) lands in audit_log
-- automatically, actor included, same as every other master-table edit.
create trigger audit_customer_installed_products after insert or update or delete
  on public.customer_installed_products for each row execute function public.audit_master_change();
create trigger audit_customer_part_schedules after insert or update or delete
  on public.customer_part_schedules for each row execute function public.audit_master_change();

alter table public.customer_installed_products enable row level security;
alter table public.customer_part_schedules enable row level security;

-- No direct client INSERT/UPDATE/DELETE policy on either table anywhere below —
-- all writes go through security-definer RPCs (matches lead_followups' and
-- installations_logged's RPC-only house style). SELECT only, three ways:
-- org-wide staff, the owning customer, and a technician scoped to tickets
-- they have actually worked for that customer.

create policy customer_installed_products_select_staff on public.customer_installed_products
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_installed_products_select_own on public.customer_installed_products
  for select using (customer_id = public.current_customer_id());
create policy customer_installed_products_select_technician on public.customer_installed_products
  for select using (
    exists (
      select 1 from public.service_visits v
      join public.service_tickets st on st.id = v.ticket_id
      where st.customer_id = customer_installed_products.customer_id
        and v.technician_id = public.current_technician_id()
    )
  );

create policy customer_part_schedules_select_staff on public.customer_part_schedules
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_part_schedules_select_own on public.customer_part_schedules
  for select using (
    exists (
      select 1 from public.customer_installed_products cip
      where cip.id = customer_part_schedules.installed_product_id
        and cip.customer_id = public.current_customer_id()
    )
  );
create policy customer_part_schedules_select_technician on public.customer_part_schedules
  for select using (
    exists (
      select 1 from public.customer_installed_products cip
      join public.service_visits v on v.ticket_id in (
        select st.id from public.service_tickets st where st.customer_id = cip.customer_id
      )
      where cip.id = customer_part_schedules.installed_product_id
        and v.technician_id = public.current_technician_id()
    )
  );

revoke all on public.customer_installed_products from public, anon;
revoke all on public.customer_part_schedules from public, anon;
grant select, insert, update, delete on public.customer_installed_products to authenticated;
grant select, insert, update, delete on public.customer_part_schedules to authenticated;
