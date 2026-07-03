-- Phase 9 (Automation, Purchasing & Leads) — schema additions.
--
-- `purchase_orders` (header) already exists from Phase 1 (BuildSpec §5) but
-- has no line-items table yet — ADM-20/21 need per-item qty/price on a PO.
-- `leads`/`automation_flows`/`video_library`/`referral_points` already exist
-- with full RLS from Phase 1; this migration only adds what's genuinely
-- missing: PO line items, a logged outbox standing in for the WhatsApp Cloud
-- API (no real credentials exist in this environment — every "send" in this
-- app is logged, not dispatched, matching the pattern already used for
-- warranty reminders/milestone notifications elsewhere), and the PO
-- approval-value threshold referenced by `approval_type = 'po'` (that enum
-- value already existed, unused until now).

create table public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  po_id uuid not null references public.purchase_orders (id) on delete cascade,
  item_type public.item_type not null,
  item_id uuid not null,
  qty integer not null check (qty > 0),
  price numeric(12, 2) not null default 0 check (price >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index purchase_order_items_po_id_idx on public.purchase_order_items (po_id);
create index purchase_order_items_org_id_idx on public.purchase_order_items (org_id);

alter table public.purchase_order_items enable row level security;

create policy purchase_order_items_select_staff on public.purchase_order_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_order_items_write_ops on public.purchase_order_items for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- A logged "send" — the closest honest equivalent of a WhatsApp Cloud API
-- call this environment can make. `direction` distinguishes outbound sends
-- (milestones, PO-to-supplier, flow actions) from simulated inbound
-- messages fed into `simulate_inbound_whatsapp` (the SQL-level stand-in for
-- the spec's `/api/whatsapp/webhook` route — this is a Vite SPA with no
-- server to host a real HTTP route on; a real deployment would point an
-- Edge Function webhook at this same table/function pair).
create table public.whatsapp_outbox (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  direction text not null default 'outbound' check (direction in ('outbound', 'inbound')),
  to_mobile text,
  customer_id uuid references public.customers (id) on delete set null,
  milestone text,
  template text not null,
  payload jsonb not null default '{}'::jsonb,
  ref_type text,
  ref_id uuid,
  status text not null default 'sent' check (status in ('sent', 'failed', 'received')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index whatsapp_outbox_org_id_idx on public.whatsapp_outbox (org_id, created_at desc);
create index whatsapp_outbox_ref_idx on public.whatsapp_outbox (ref_type, ref_id);

alter table public.whatsapp_outbox enable row level security;

create policy whatsapp_outbox_select_staff on public.whatsapp_outbox
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy whatsapp_outbox_insert_staff on public.whatsapp_outbox
  for insert with check (org_id = public.current_org_id() and public.is_staff());

-- v2.2 §6.1-adjacent: PO value above this threshold needs master approval
-- before being sent (approval_type = 'po', already defined in the Phase 1
-- enum, unused until this phase). Admin-editable like every other settings
-- figure — no fixed business number hardcoded elsewhere.
alter table public.settings
  add column if not exists po_approval_threshold numeric(12, 2) not null default 20000 check (po_approval_threshold >= 0);
