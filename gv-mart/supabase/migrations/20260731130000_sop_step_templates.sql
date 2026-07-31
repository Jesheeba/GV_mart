-- Technician Module Audit, Task 5 — authorized as a new change request
-- (2026-07-31): building an admin-managed SOP step master was explicitly
-- declined once before (2026-07-08, see OnSiteVisitPage.tsx's old comment
-- "a 'SOP master' screen is explicitly out of v2.2 scope") because it wasn't
-- in the client-signed scope doc. The user now explicitly authorizes it as a
-- new change request, superseding that earlier decision.
--
-- Same shape as the other Masters tables (gifts/products/spares — see
-- 20260701091300_rls.sql): org-scoped read for any authenticated org member
-- (technicians need this to populate the on-site step picker), write
-- restricted to master.
--
-- p_product_id nullable: a template can be product-specific (e.g. an
-- RO-only maintenance step) or org-wide/generic (no product set) — the
-- technician-side picker filters by the ticket's product, falling back to
-- the generic pool. This mirrors spares.product_id's own nullable pattern.
create table public.sop_step_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid references public.products (id) on delete cascade,
  name text not null,
  default_expected_minutes integer not null default 10 check (default_expected_minutes > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index sop_step_templates_org_id_idx on public.sop_step_templates (org_id);
create index sop_step_templates_product_id_idx on public.sop_step_templates (product_id);

create trigger set_updated_at
  before update on public.sop_step_templates
  for each row execute function public.set_updated_at();

alter table public.sop_step_templates enable row level security;

create policy sop_step_templates_select_org on public.sop_step_templates
  for select using (org_id = public.current_org_id());

create policy sop_step_templates_write_master on public.sop_step_templates for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
