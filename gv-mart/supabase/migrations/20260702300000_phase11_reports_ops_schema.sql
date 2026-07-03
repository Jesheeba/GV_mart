-- Phase 11 (Reports & system/ops pages) — new tables only.
--
-- ADM-35 Campaign Manager needs `campaigns`; ADM-37 Returns/Replacement
-- needs `returns`. Everything else in Phase 11 (Reports hub, Workspace,
-- Notifications Center, Approvals Queue, Complaints & Escalations, Audit Log
-- viewer, technician Day-Sheet) reads existing tables (service_tickets,
-- ratings, notifications, approvals, tasks, audit_log, invoices, expenses,
-- lead_activities, service_visits) — no new tables needed for those.
--
-- Reuses existing helper functions from 20260701091200_functions_triggers.sql
-- (current_org_id, is_sales_staff, is_ops_staff, is_staff) — not redefined.

-- ── ADM-35 Campaign Manager ─────────────────────────────────────────────
-- No real WhatsApp/SMS send integration exists anywhere in this codebase
-- (BuildSpec Phase 9's automation is a separate in-flight phase; even that
-- phase's "send" is app-side logging, not a real gateway). Campaigns here
-- are create/track only — `status` moves draft -> active -> completed by
-- admin action, never by an actual dispatch job.
create table campaigns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  name text not null,
  channel text not null,
  target_segment text,
  status text not null default 'draft' check (status in ('draft', 'active', 'completed')),
  start_date date,
  end_date date,
  message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index campaigns_org_id_idx on campaigns (org_id);
create index campaigns_status_idx on campaigns (org_id, status);

alter table campaigns enable row level security;

create policy campaigns_select_staff on campaigns
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy campaigns_write_sales on campaigns for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

-- ── ADM-37 Returns / Replacement ────────────────────────────────────────
-- Ties back to an invoice line (item_type/item_id mirrors invoice_items'
-- own item_type/item_id convention used throughout Phase 4/5). No inventory
-- trigger is wired automatically here — "completed" returns/replacements
-- are logged for ops visibility; an ops user reconciles stock via the
-- existing Inventory screen's manual adjustment, same as every other
-- non-automated stock event in this build so far.
create table returns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  invoice_id uuid not null references invoices (id) on delete restrict,
  item_type item_type not null,
  item_id uuid not null,
  qty integer not null check (qty > 0),
  reason text,
  status text not null default 'requested' check (status in ('requested', 'approved', 'completed', 'rejected')),
  is_replacement boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index returns_org_id_idx on returns (org_id);
create index returns_invoice_id_idx on returns (invoice_id);
create index returns_status_idx on returns (org_id, status);

alter table returns enable row level security;

create policy returns_select_staff on returns
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy returns_write_ops on returns for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
