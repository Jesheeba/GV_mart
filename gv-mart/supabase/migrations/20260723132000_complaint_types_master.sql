-- STEP 6.4 (Meeting spec E1) — Complaint-name master, product-tagged,
-- admin-editable. SCOPE-GUARD item, explicitly re-authorized by the Build
-- Order this pass (previously declined).
--
-- Tagged by product CATEGORY (brand_category: ro/ac/inverter/battery), not
-- by individual product_id — the spec's own examples ("AC -> Not Cooling,
-- Sound Problem, Leakage; RO -> No Water, No Taste") are category-level, a
-- complaint type is naturally shared across every model in a category, and
-- both consuming screens (customer booking, admin new-complaint) already
-- resolve a category for whatever product is selected. Mirrors
-- amc_plans/brands/gifts exactly: org-scoped master, select open to every
-- authenticated org member (staff, technicians, customers all need to read
-- it — same reasoning as the "Catalog & inventory" RLS block), write
-- restricted to master.

create table public.complaint_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_category brand_category not null,
  label text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index complaint_types_org_id_idx on public.complaint_types (org_id);
create index complaint_types_category_idx on public.complaint_types (org_id, product_category);

alter table public.complaint_types enable row level security;

create policy complaint_types_select_org on public.complaint_types for select using (org_id = public.current_org_id());
create policy complaint_types_write_master on public.complaint_types for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_complaint_types after insert or update or delete on public.complaint_types for each row execute function public.audit_master_change();
