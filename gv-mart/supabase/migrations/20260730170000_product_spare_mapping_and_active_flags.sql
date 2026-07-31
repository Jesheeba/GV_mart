-- Task 6 (Customer Dashboard enhancement spec, 2026-07-30): centralized
-- Product & Spare Parts management.
--
-- 1. Enable/Disable flags on products/spares — the write RLS/audit pattern
--    already matches complaint_types exactly (org-scoped select, master-only
--    write, audit_master_change trigger), so this only adds the column.
-- 2. product_spares — many-to-many product<->spare mapping ("assign
--    multiple spare parts to products"). Unlike complaint_types (category
--    default + per-product hybrid), spares have no category concept today —
--    a flat junction table is the right shape.
--
-- No new RPCs needed: products/spares already allow direct client
-- inserts/updates/deletes under RLS for is_master() — bulk import/update
-- (Task 6's admin requirements) are plain batched .insert()/.update() calls
-- from the client, same as every other masters.ts entity.

alter table public.products add column if not exists is_active boolean not null default true;
alter table public.spares add column if not exists is_active boolean not null default true;

create table if not exists public.product_spares (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  spare_id uuid not null references public.spares (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (product_id, spare_id)
);

create index if not exists product_spares_org_id_idx on public.product_spares (org_id);
create index if not exists product_spares_product_id_idx on public.product_spares (product_id);
create index if not exists product_spares_spare_id_idx on public.product_spares (spare_id);

alter table public.product_spares enable row level security;

-- Same shape as products_select_org/spares_select_org: every org member
-- (staff, technicians, customers) can read the mapping — the customer Spare
-- Enquiry picker needs it directly, RLS-respecting, with no RPC.
create policy product_spares_select_org on public.product_spares for select using (org_id = public.current_org_id());
create policy product_spares_write_master on public.product_spares for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_product_spares after insert or update or delete on public.product_spares for each row execute function public.audit_master_change();
