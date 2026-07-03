-- v2.2 §6.5 gap fixes, found during a final Section-6 compliance sweep after
-- Phase 9-11 landed:
--   "A lunch break of 30 minutes is allowed. More than 45 minutes shows as
--    red." — settings.lunch_minutes_allowed/lunch_minutes_red_threshold
--    already existed (admin-settable), but nothing tracked an actual lunch
--    start/end anywhere.
--   "Touching the number starts the call, and calls are tracked and
--    recorded." — tel: links existed (JobDetailPage/SearchPage) but no call
--    was ever logged; Reports' "Sales Calls" figure was a lead_activities
--    proxy for lack of a real source.

alter table public.attendance
  add column if not exists lunch_start timestamptz,
  add column if not exists lunch_end timestamptz;

create table public.call_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid references public.technicians (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  ticket_id uuid references public.service_tickets (id) on delete set null,
  called_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index call_logs_org_id_idx on public.call_logs (org_id, called_at desc);
create index call_logs_technician_id_idx on public.call_logs (technician_id);

alter table public.call_logs enable row level security;

create policy call_logs_select_staff on public.call_logs
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy call_logs_insert_staff on public.call_logs
  for insert with check (org_id = public.current_org_id() and public.is_staff());
create policy call_logs_insert_own_technician on public.call_logs
  for insert with check (technician_id = public.current_technician_id());
