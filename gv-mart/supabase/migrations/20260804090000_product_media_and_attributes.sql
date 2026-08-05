-- Product Enquiry rebuild (2026-08-04), Phase 1: Product Management redesign.
-- Client wants the customer-facing Product Enquiry section rebuilt as an
-- admin-configurable e-commerce-style catalog. Phase 1 lays the per-product
-- groundwork this needs — multiple photos, documents, videos, unlimited
-- custom attributes, feature bullets, related products, and per-product
-- CTA overrides — with zero customer-facing change yet (that's Phases 3-5).
--
-- Architectural note: this codebase has an explicit documented stance
-- against generic key-value/EAV tables (see settings, 20260701091100_
-- system.sql's header comment: "modelled as one typed row per org, not a
-- generic key/value table"), and there is no EAV pattern anywhere else in
-- this schema. Custom attributes below follow the same style already used
-- by amc_plans.inclusions (a bounded jsonb column, no DB-level content
-- validation, runtime-guarded on the client) rather than introducing a
-- first-ever EAV child table — product_attribute_keys (added in Phase 2,
-- since filters/comparison-fields need it too) is the typed half that keeps
-- the jsonb half from typo-drifting.
--
-- product_images/product_documents/product_videos are real child tables
-- (not jsonb) because they need per-item identity (id, storage cleanup,
-- is_primary) — contrast with feature_bullets, which is just a list of
-- strings with no per-item metadata, so it's a plain jsonb array exactly
-- like service_visits.evidence_photo_urls already is.
--
-- product_enquiry_cta_type is defined here (not in the Phase 2 config
-- migration) because product_cta_overrides needs it now; Phase 2's
-- product_enquiry_cta_config reuses this same enum rather than duplicating
-- the type.

create type public.product_enquiry_cta_type as enum ('quotation', 'callback', 'share');

-- ── 1. Product images ────────────────────────────────────────────────────
create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  storage_path text not null,
  sort_order integer not null default 0,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_images_org_id_idx on public.product_images (org_id);
create index product_images_product_id_idx on public.product_images (product_id);
-- At most one primary image per product, enforced at the DB level.
create unique index product_images_one_primary_idx on public.product_images (product_id) where is_primary;

alter table public.product_images enable row level security;
create policy product_images_select_org on public.product_images for select using (org_id = public.current_org_id());
create policy product_images_write_master on public.product_images for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_images after insert or update or delete on public.product_images for each row execute function public.audit_master_change();

-- ── 2. Product documents (brochure/manual/warranty card) ────────────────
create table public.product_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  storage_path text not null,
  label text not null,
  doc_type text not null default 'other' check (doc_type in ('brochure', 'manual', 'warranty_card', 'other')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_documents_org_id_idx on public.product_documents (org_id);
create index product_documents_product_id_idx on public.product_documents (product_id);

alter table public.product_documents enable row level security;
create policy product_documents_select_org on public.product_documents for select using (org_id = public.current_org_id());
create policy product_documents_write_master on public.product_documents for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_documents after insert or update or delete on public.product_documents for each row execute function public.audit_master_change();

-- ── 3. Product videos (per-product media gallery — distinct from
-- video_library, which stays as-is for the topic-driven enquiry flow) ─────
create table public.product_videos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  url text not null,
  title text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_videos_org_id_idx on public.product_videos (org_id);
create index product_videos_product_id_idx on public.product_videos (product_id);

alter table public.product_videos enable row level security;
create policy product_videos_select_org on public.product_videos for select using (org_id = public.current_org_id());
create policy product_videos_write_master on public.product_videos for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_videos after insert or update or delete on public.product_videos for each row execute function public.audit_master_change();

-- ── 4. Custom attributes + feature bullets on products ──────────────────
-- custom_attributes is a map keyed by product_attribute_keys.id (text form
-- of the uuid) -> value (text/number/boolean per that key's data_type).
-- feature_bullets is a plain ordered array of strings (no per-item
-- metadata needed, unlike images/documents).
alter table public.products add column if not exists custom_attributes jsonb not null default '{}'::jsonb;
alter table public.products add column if not exists feature_bullets jsonb not null default '[]'::jsonb;

-- ── 5. Related products / accessories ───────────────────────────────────
create table public.product_related (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  related_product_id uuid not null references public.products (id) on delete cascade,
  relation_type text not null default 'related' check (relation_type in ('accessory', 'related', 'frequently_bought_with')),
  created_at timestamptz not null default now(),
  unique (product_id, related_product_id, relation_type),
  check (product_id <> related_product_id)
);

create index product_related_org_id_idx on public.product_related (org_id);
create index product_related_product_id_idx on public.product_related (product_id);

alter table public.product_related enable row level security;
create policy product_related_select_org on public.product_related for select using (org_id = public.current_org_id());
create policy product_related_write_master on public.product_related for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_related after insert or update or delete on public.product_related for each row execute function public.audit_master_change();

-- ── 6. Per-product CTA overrides ────────────────────────────────────────
-- Same category-default-OR-specific-override hybrid already used by
-- complaint_types (20260729140000_complaint_types_per_product.sql): only
-- rows that DEVIATE from the org-wide default (product_enquiry_cta_config,
-- added in Phase 2) exist here. Merge logic (org default, product override
-- wins if present) is done client-side, same as complaint types.
create table public.product_cta_overrides (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  cta_type public.product_enquiry_cta_type not null,
  is_enabled boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, cta_type)
);

create index product_cta_overrides_org_id_idx on public.product_cta_overrides (org_id);
create index product_cta_overrides_product_id_idx on public.product_cta_overrides (product_id);

alter table public.product_cta_overrides enable row level security;
create policy product_cta_overrides_select_org on public.product_cta_overrides for select using (org_id = public.current_org_id());
create policy product_cta_overrides_write_master on public.product_cta_overrides for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_cta_overrides after insert or update or delete on public.product_cta_overrides for each row execute function public.audit_master_change();
