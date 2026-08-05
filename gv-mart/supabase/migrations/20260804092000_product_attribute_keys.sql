-- Product Enquiry rebuild (2026-08-04), Phase 1 continued.
--
-- Pulled forward from the Phase 2 module-config migration: the Phase 1
-- admin custom-attribute editor (ProductAttributesPanel.tsx) needs a stable
-- key catalog to pick from *now*, not just once filters/comparison-fields
-- (Phase 2) reference it. This is the typed half that keeps
-- products.custom_attributes jsonb (20260804090000) from typo-drifting —
-- it's the only place new attribute keys get created; both the admin
-- attribute editor and, later, the filter/comparison-field config UI
-- populate their key dropdowns from this table, never a free-text input.

create table public.product_attribute_keys (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  key_name text not null,
  label text not null,
  data_type text not null default 'text' check (data_type in ('text', 'number', 'boolean')),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, key_name)
);

create index product_attribute_keys_org_id_idx on public.product_attribute_keys (org_id);

alter table public.product_attribute_keys enable row level security;
create policy product_attribute_keys_select_org on public.product_attribute_keys for select using (org_id = public.current_org_id());
create policy product_attribute_keys_write_master on public.product_attribute_keys for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_attribute_keys after insert or update or delete on public.product_attribute_keys for each row execute function public.audit_master_change();
