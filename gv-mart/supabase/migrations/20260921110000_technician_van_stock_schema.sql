-- Technician van stock, Group 1 (schema).
--
-- Today's audit found the plumbing for this already half-built:
--   - `inventory` already has a `location` column with a 'van' value
--     (20260701090000_extensions_and_enums.sql), and create_spare_handover /
--     create_service_invoice already move stock into/out of
--     `location = 'van'` rows.
--   - `spare_handover_items.qty_returned` already exists and is already
--     rendered by TechniciansSpareHandoverPage.tsx — nothing has ever written
--     to it.
-- But the 'van' row for a given spare is a single ORG-WIDE pooled bucket
-- (`inventory`'s unique index is (org_id, item_type, item_id, location) —
-- no technician dimension at all). So today, every technician's van stock
-- for a spare is the same shared number: handing 5 units to technician A and
-- 3 to technician B both land in the one 'van' row (8), and either
-- technician's service-use deduction can silently consume the other's
-- stock. That pooling is the real gap "who holds what" needs fixed, not
-- just a missing return flow.
--
-- Fix: a proper per-technician ledger table, `technician_stock_levels`,
-- becomes the source of truth for van-held stock going forward.
-- `inventory` keeps meaning "warehouse" only from here on (existing
-- location='van' rows are left in place, inert — dropping an enum value
-- isn't reversible and nothing still writes there after this feature's
-- follow-up migrations land).

create table technician_stock_levels (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  item_type item_type not null,
  item_id uuid not null,
  stock_qty integer not null default 0 check (stock_qty >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index technician_stock_levels_org_id_idx on technician_stock_levels (org_id);
create index technician_stock_levels_technician_id_idx on technician_stock_levels (technician_id);
create unique index technician_stock_levels_item_idx
  on technician_stock_levels (org_id, technician_id, item_type, item_id);

alter table technician_stock_levels enable row level security;

create policy technician_stock_levels_select_staff on technician_stock_levels
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy technician_stock_levels_select_own on technician_stock_levels
  for select using (technician_id = public.current_technician_id());
-- Written only by security-definer RPCs (create_spare_handover,
-- create_spare_return, create_service_invoice), which bypass RLS — no
-- direct-write policy needed, same as `inventory` has none for van rows today.

-- Return flow header + items — deliberately NOT a dual-signature workflow
-- like spare_handovers: a handover needs two parties to independently
-- attest to a real-world handoff that happens outside the app first; a
-- return recorded here IS the event (ops staff enters what a technician
-- physically handed back, atomically decrementing their van stock in the
-- same transaction), so there's no pending/confirmed gap to model.
create table spare_returns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  technician_id uuid not null references technicians (id) on delete cascade,
  date date not null default (now() at time zone 'Asia/Kolkata')::date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index spare_returns_org_id_idx on spare_returns (org_id);
create index spare_returns_technician_id_idx on spare_returns (technician_id);

create table spare_return_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations (id) on delete cascade,
  return_id uuid not null references spare_returns (id) on delete cascade,
  spare_id uuid not null references spares (id) on delete restrict,
  qty_returned integer not null check (qty_returned > 0),
  created_at timestamptz not null default now()
);

create index spare_return_items_return_id_idx on spare_return_items (return_id);

alter table spare_returns enable row level security;
alter table spare_return_items enable row level security;

create policy spare_returns_select_staff on spare_returns
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy spare_returns_select_own on spare_returns
  for select using (technician_id = public.current_technician_id());
-- Writes go through create_spare_return (security definer, is_ops_staff()
-- gated) — no direct-write policy, matching technician_stock_levels above.

create policy spare_return_items_select_staff on spare_return_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy spare_return_items_select_own on spare_return_items
  for select using (
    exists (select 1 from spare_returns r where r.id = return_id and r.technician_id = public.current_technician_id())
  );

-- Reporting attribution: which technician a movement belongs to. Nullable —
-- 'sale'/'purchase_receipt'/warehouse-side movements have no technician.
-- Populated going forward by create_spare_handover, create_spare_return, and
-- create_service_invoice's van/warehouse deduction (next migrations in this
-- group); backfilling historical rows isn't attempted since the only prior
-- movement reason that touched van stock ('spare_handover') was writing to
-- the pooled bucket this feature is replacing, so there's no correct
-- per-technician value to backfill it with.
alter table inventory_movements add column technician_id uuid references technicians (id) on delete set null;
create index inventory_movements_technician_id_idx on inventory_movements (technician_id) where technician_id is not null;
