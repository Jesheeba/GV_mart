-- Product Enquiry rebuild (2026-08-04), Phase 2: admin-configurable module
-- layer (tabs / filters / comparison fields / CTA config) driving the
-- customer-facing Product Enquiry screen (Phases 3-5). product_enquiry_
-- cta_type already exists (20260804090000) since Phase 1's per-product CTA
-- overrides needed it first — product_enquiry_cta_config below reuses it
-- rather than redefining it.
--
-- Kept as 4 separate tables (not one "module_kind"-discriminated table):
-- tabs/filters/comparison-fields/CTAs are queried independently by
-- different customer pages at different times, and this codebase's actual
-- habit (product_spares vs complaint_types vs appointment_slots — similar
-- shape, kept as separate tables) confirms "one table per real concept,
-- unified only at the jsonb-config level" is the house style here, not a
-- single generic dispatch table (which would be EAV-by-another-name).
--
-- EMI is folded into settings (3 new columns) rather than its own table —
-- it's a tiny singleton (tenure list + disclaimer + on/off), the same shape
-- as amc_book_window_days/referral_point_value already on settings.

create type public.product_enquiry_tab_type as enum ('catalog_grid', 'video_library');
create type public.product_enquiry_field as enum ('category', 'brand', 'price_range');

-- ── 1. Tabs ──────────────────────────────────────────────────────────────
create table public.product_enquiry_tabs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  tab_type public.product_enquiry_tab_type not null,
  label text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  -- Bounded per tab_type: video_library -> {"topics": [enquiry_type...]}
  -- (an admin-editable ordered subset of the enquiry_type enum, replacing
  -- the hardcoded TOPICS array in CustomerProductEnquiryPage.tsx);
  -- catalog_grid -> {} (reserved; the grid itself is driven by
  -- product_enquiry_filters, not per-tab config).
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_enquiry_tabs_org_id_idx on public.product_enquiry_tabs (org_id);

alter table public.product_enquiry_tabs enable row level security;
create policy product_enquiry_tabs_select_org on public.product_enquiry_tabs for select using (org_id = public.current_org_id());
create policy product_enquiry_tabs_write_master on public.product_enquiry_tabs for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_enquiry_tabs after insert or update or delete on public.product_enquiry_tabs for each row execute function public.audit_master_change();

-- ── 2. Filters ───────────────────────────────────────────────────────────
create table public.product_enquiry_filters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_field public.product_enquiry_field,
  attribute_key_id uuid references public.product_attribute_keys (id) on delete cascade,
  label text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  -- e.g. price_range -> {"buckets": [0, 5000, 10000, 20000]}
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Exactly one of product_field / attribute_key_id — a fixed base-product
  -- field, or a custom attribute, never both/neither.
  check ((product_field is null) <> (attribute_key_id is null))
);

create index product_enquiry_filters_org_id_idx on public.product_enquiry_filters (org_id);

alter table public.product_enquiry_filters enable row level security;
create policy product_enquiry_filters_select_org on public.product_enquiry_filters for select using (org_id = public.current_org_id());
create policy product_enquiry_filters_write_master on public.product_enquiry_filters for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_enquiry_filters after insert or update or delete on public.product_enquiry_filters for each row execute function public.audit_master_change();

-- ── 3. Comparison fields ─────────────────────────────────────────────────
-- Same shape as filters, kept as an independent table/list (not a shared
-- "usage" flag on filters) since a field can be worth comparing without
-- being a filter chip (e.g. warranty months) and vice versa.
create table public.product_enquiry_comparison_fields (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_field public.product_enquiry_field,
  attribute_key_id uuid references public.product_attribute_keys (id) on delete cascade,
  label text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((product_field is null) <> (attribute_key_id is null))
);

create index product_enquiry_comparison_fields_org_id_idx on public.product_enquiry_comparison_fields (org_id);

alter table public.product_enquiry_comparison_fields enable row level security;
create policy product_enquiry_comparison_fields_select_org on public.product_enquiry_comparison_fields for select using (org_id = public.current_org_id());
create policy product_enquiry_comparison_fields_write_master on public.product_enquiry_comparison_fields for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_enquiry_comparison_fields after insert or update or delete on public.product_enquiry_comparison_fields for each row execute function public.audit_master_change();

-- ── 4. CTA config (org-wide defaults; product_cta_overrides from Phase 1
-- overrides these per-product) ──────────────────────────────────────────
create table public.product_enquiry_cta_config (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  cta_type public.product_enquiry_cta_type not null,
  label text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  -- Bounded per cta_type:
  --   quotation -> {"qty_stepper_enabled": bool, "min_qty": int, "max_qty": int, "note_field_enabled": bool}
  --   callback  -> {"max_days_ahead": int}  (mirrors settings.amc_book_window_days'
  --                "how many days ahead" idiom; slot mechanics stay entirely
  --                on appointment_slots, not redefined here)
  --   share     -> {"fields": ["name","price","emi","brand"]}
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, cta_type)
);

create index product_enquiry_cta_config_org_id_idx on public.product_enquiry_cta_config (org_id);

alter table public.product_enquiry_cta_config enable row level security;
create policy product_enquiry_cta_config_select_org on public.product_enquiry_cta_config for select using (org_id = public.current_org_id());
create policy product_enquiry_cta_config_write_master on public.product_enquiry_cta_config for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_enquiry_cta_config after insert or update or delete on public.product_enquiry_cta_config for each row execute function public.audit_master_change();

-- ── 5. EMI settings (folded into settings, not a new table) ─────────────
alter table public.settings
  add column if not exists emi_enabled boolean not null default true,
  add column if not exists emi_tenure_months jsonb not null default '[6, 12, 24]'::jsonb,
  add column if not exists emi_disclaimer text;

-- ── 6. Seed data — preserve today's live topic/video behavior exactly, and
-- give every org sensible net-new defaults for everything else. ─────────
insert into public.product_enquiry_tabs (org_id, tab_type, label, sort_order, is_active, config)
select id, 'video_library'::public.product_enquiry_tab_type, 'Videos & Topics', 1, true,
  '{"topics": ["online", "price", "quality", "customization", "water_premium", "budget"]}'::jsonb
from public.organizations;

insert into public.product_enquiry_tabs (org_id, tab_type, label, sort_order, is_active)
select id, 'catalog_grid'::public.product_enquiry_tab_type, 'Catalog', 0, true from public.organizations;

insert into public.product_enquiry_cta_config (org_id, cta_type, label, sort_order, is_active, config)
select id, 'quotation'::public.product_enquiry_cta_type, 'Request Quotation', 0, true,
  '{"qty_stepper_enabled": true, "min_qty": 1, "max_qty": 10, "note_field_enabled": true}'::jsonb
from public.organizations
union all
select id, 'callback'::public.product_enquiry_cta_type, 'Request Callback', 1, true, '{"max_days_ahead": 15}'::jsonb from public.organizations
union all
select id, 'share'::public.product_enquiry_cta_type, 'Share', 2, true, '{"fields": ["name", "price", "brand"]}'::jsonb from public.organizations;

insert into public.product_enquiry_filters (org_id, product_field, label, sort_order, is_active)
select id, 'category'::public.product_enquiry_field, 'Category', 0, true from public.organizations
union all select id, 'brand'::public.product_enquiry_field, 'Brand', 1, true from public.organizations
union all select id, 'price_range'::public.product_enquiry_field, 'Price', 2, true from public.organizations;

insert into public.product_enquiry_comparison_fields (org_id, product_field, label, sort_order, is_active)
select id, 'category'::public.product_enquiry_field, 'Category', 0, true from public.organizations
union all select id, 'brand'::public.product_enquiry_field, 'Brand', 1, true from public.organizations
union all select id, 'price_range'::public.product_enquiry_field, 'Price', 2, true from public.organizations;
