-- Credential storage for the Wasi WhatsApp BSP connector (and any future
-- non-Meta provider) — deliberately a separate table from
-- whatsapp_business_numbers rather than new columns on it: that table is
-- "one row per Meta phone number," a different axis of variation from "one
-- credential bundle per (org, provider)". provider is a plain text column
-- (not an enum) so a second provider never needs a migration to add.
--
-- waba_id is how wasi-webhook resolves org_id from an inbound
-- message.received payload (Wasi's webhook_secret is per-client, so the
-- org must be resolved from the payload BEFORE the signature can be
-- verified — see wasi-webhook/index.ts). client_id/api_key are outbound-only
-- (the future sendMessage() provider branch, not built in this pass).
create table public.whatsapp_provider_credentials (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  provider text not null,
  waba_id text,
  client_id text,
  api_key text not null,
  webhook_secret text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, provider),
  unique (provider, waba_id)
);

create index whatsapp_provider_credentials_org_id_idx on public.whatsapp_provider_credentials (org_id);

alter table public.whatsapp_provider_credentials enable row level security;

-- Mirrors whatsapp_business_numbers' existing RLS shape exactly: staff can
-- see it (needed to review which providers are wired up), only ops can
-- write it (a credential is operational configuration, not sales/day-to-day
-- data). Never selected from any client-side query in this codebase —
-- reads are service-role only, from wasi-webhook and the future sendMessage().
create policy whatsapp_provider_credentials_select_staff on public.whatsapp_provider_credentials
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy whatsapp_provider_credentials_write_ops on public.whatsapp_provider_credentials for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
