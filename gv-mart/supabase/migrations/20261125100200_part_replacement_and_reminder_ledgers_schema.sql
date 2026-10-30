-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 3/8.
-- Append-only replacement history + the reminder dedupe ledgers.

create table public.part_replacement_history (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id),
  replaced_date date not null,
  previous_due_date date not null,
  next_due_date date not null,
  spare_used_id uuid references public.spares (id),
  recorded_by uuid references public.profiles (id),
  visit_id uuid references public.service_visits (id),
  note text,
  created_at timestamptz not null default now()
);

create index part_replacement_history_schedule_idx
  on public.part_replacement_history (customer_part_schedule_id);
create index part_replacement_history_org_idx on public.part_replacement_history (org_id);

create trigger audit_part_replacement_history after insert or update or delete
  on public.part_replacement_history for each row execute function public.audit_master_change();

alter table public.part_replacement_history enable row level security;

create policy part_replacement_history_select_staff on public.part_replacement_history
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy part_replacement_history_select_own on public.part_replacement_history
  for select using (
    exists (
      select 1 from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where cps.id = part_replacement_history.customer_part_schedule_id
        and cip.customer_id = public.current_customer_id()
    )
  );
create policy part_replacement_history_select_technician on public.part_replacement_history
  for select using (
    recorded_by = auth.uid()
    or exists (
      select 1 from public.service_visits v
      where v.id = part_replacement_history.visit_id
        and v.technician_id = public.current_technician_id()
    )
  );

revoke all on public.part_replacement_history from public, anon;
grant select, insert on public.part_replacement_history to authenticated;

-- Dedupe ledgers: internal to the cron job only. RLS enabled, zero client
-- policies (not even staff select) — nothing but the SECURITY DEFINER
-- reminder function and this migration ever touches these rows.
create table public.lifecycle_reminder_events (
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id) on delete cascade,
  due_date date not null,
  stage text not null check (stage in ('t_minus_14', 't_minus_7', 'due', 'overdue_3', 'overdue_7', 'backfill_consolidated')),
  created_at timestamptz not null default now(),
  primary key (customer_part_schedule_id, due_date, stage)
);

create table public.lifecycle_expiry_reminder_events (
  org_id uuid not null references public.organizations (id) on delete cascade,
  installed_product_id uuid not null references public.customer_installed_products (id) on delete cascade,
  due_date date not null,
  stage text not null check (stage in ('t_minus_14', 't_minus_7', 'due', 'overdue_3', 'overdue_7')),
  created_at timestamptz not null default now(),
  primary key (installed_product_id, due_date, stage)
);

alter table public.lifecycle_reminder_events enable row level security;
alter table public.lifecycle_expiry_reminder_events enable row level security;

revoke all on public.lifecycle_reminder_events from public, anon, authenticated;
revoke all on public.lifecycle_expiry_reminder_events from public, anon, authenticated;
