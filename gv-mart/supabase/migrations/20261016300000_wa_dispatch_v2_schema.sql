-- WhatsApp dispatcher v2, step 1 of 2: additive schema. See docs/plan-dispatcher-fix.md (a).
--
-- Safe to apply on its own: every new column is nullable/defaulted, the status CHECK is only widened, and nothing in the
-- application reads the new objects until settings.wa_dispatch_v2_enabled is switched on (it ships OFF).
-- The pending-normalisation trigger is the NEXT migration (20261016310000) so it can be applied last.
--
-- Rollback (kept in docs/plan-dispatcher-fix-deploy.md): the flag goes off first; this migration is left in place.

-- ── whatsapp_outbox: states + delivery columns ───────────────────────────────────────────────────────────────────────
alter table public.whatsapp_outbox drop constraint if exists whatsapp_outbox_status_check;
alter table public.whatsapp_outbox
  add constraint whatsapp_outbox_status_check
  check (status in ('pending', 'sent', 'failed', 'received', 'skipped_no_template'));

alter table public.whatsapp_outbox
  add column if not exists wasi_message_id text,      -- Wasi's own id; wa_message_id is the WhatsApp id (meta_message_id)
  add column if not exists delivery_status text,      -- sent | delivered | read | failed, from message.status webhooks
  add column if not exists delivered_at timestamptz,
  add column if not exists read_at timestamptz,
  add column if not exists failed_at timestamptz,
  add column if not exists claimed_at timestamptz,    -- claim-before-send marker
  add column if not exists wasi_response jsonb,       -- cleaned send response / error object (no number, no wamid)
  add column if not exists template_name text,        -- Wasi template actually used
  add column if not exists template_params jsonb;     -- params sent with it

alter table public.whatsapp_outbox drop constraint if exists whatsapp_outbox_delivery_status_check;
alter table public.whatsapp_outbox
  add constraint whatsapp_outbox_delivery_status_check
  check (delivery_status is null or delivery_status in ('sent', 'delivered', 'read', 'failed'));

create index if not exists whatsapp_outbox_pending_idx
  on public.whatsapp_outbox (org_id, created_at)
  where status = 'pending' and direction = 'outbound';

-- ── 24 h window source of truth: one row per (org, last 10 digits) ───────────────────────────────────────────────────
create table if not exists public.whatsapp_contacts (
  org_id uuid not null references public.organizations (id) on delete cascade,
  phone text not null check (phone ~ '^[0-9]{10}$'),
  last_inbound_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (org_id, phone)
);

alter table public.whatsapp_contacts enable row level security;
create policy whatsapp_contacts_select_staff on public.whatsapp_contacts
  for select using (org_id = public.current_org_id() and public.is_staff());
-- no write policy: only the service role (webhook) writes, through wa_touch_contact below.
-- This project auto-grants new public tables to anon/authenticated (see the default-privileges note, 2026-08-27):
-- RLS already hides the rows, but the privileges themselves are revoked so the table is closed by two layers.
revoke all on public.whatsapp_contacts from anon, authenticated;
grant select on public.whatsapp_contacts to authenticated;

create or replace function public.wa_touch_contact(p_org_id uuid, p_phone text, p_at timestamptz default now())
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 10);
begin
  if v_phone !~ '^[0-9]{10}$' then
    return;
  end if;
  insert into public.whatsapp_contacts (org_id, phone, last_inbound_at)
  values (p_org_id, v_phone, coalesce(p_at, now()))
  on conflict (org_id, phone) do update
    set last_inbound_at = greatest(public.whatsapp_contacts.last_inbound_at, excluded.last_inbound_at),
        updated_at = now();
end;
$$;
revoke all on function public.wa_touch_contact(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.wa_touch_contact(uuid, text, timestamptz) to service_role;

-- one-time backfill from the inbound rows already logged (payload.from is the raw 91xxxxxxxxxx wa_id)
insert into public.whatsapp_contacts (org_id, phone, last_inbound_at)
select o.org_id, right(regexp_replace(o.payload ->> 'from', '[^0-9]', '', 'g'), 10), max(o.created_at)
from public.whatsapp_outbox o
where o.direction = 'inbound'
  and right(regexp_replace(coalesce(o.payload ->> 'from', ''), '[^0-9]', '', 'g'), 10) ~ '^[0-9]{10}$'
group by o.org_id, right(regexp_replace(o.payload ->> 'from', '[^0-9]', '', 'g'), 10)
on conflict (org_id, phone) do update
  set last_inbound_at = greatest(public.whatsapp_contacts.last_inbound_at, excluded.last_inbound_at);

-- ── mirror of Wasi's own template list (system-owned; refreshed by the daily job and template_status webhooks) ──────
create table if not exists public.whatsapp_wasi_templates (
  org_id uuid not null references public.organizations (id) on delete cascade,
  wasi_name text not null,
  language text not null,
  category text,
  status text not null,                 -- approved | rejected | pending ... exactly as Wasi reports
  header_type text,                     -- null | TEXT | DOCUMENT | IMAGE | VIDEO
  param_keys text[] not null default '{}'::text[],
  synced_at timestamptz not null default now(),
  primary key (org_id, wasi_name, language)
);

alter table public.whatsapp_wasi_templates enable row level security;
create policy whatsapp_wasi_templates_select_staff on public.whatsapp_wasi_templates
  for select using (org_id = public.current_org_id() and public.is_staff());
revoke all on public.whatsapp_wasi_templates from anon, authenticated;   -- written only by the service role
grant select on public.whatsapp_wasi_templates to authenticated;

-- ── event -> Wasi template mapping (master/ops editable). Names differ per language: <base>_en / <base>_ta ──────────
create table if not exists public.whatsapp_event_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  event_key text not null,              -- the outbox template label, e.g. milestone.booked, amc_reminder_30
  language text not null check (language in ('en', 'ta')),
  wasi_template_name text not null,
  param_map jsonb not null default '{}'::jsonb,   -- { "<wasi param name>": "<variable key>" }
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, event_key, language)
);

alter table public.whatsapp_event_templates enable row level security;
create policy whatsapp_event_templates_select_staff on public.whatsapp_event_templates
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy whatsapp_event_templates_write_ops on public.whatsapp_event_templates for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

revoke all on public.whatsapp_event_templates from anon;   -- authenticated keeps write, gated by the ops-staff policy above

create trigger audit_whatsapp_event_templates
  after insert or update or delete on public.whatsapp_event_templates
  for each row execute function public.audit_master_change();

create trigger set_updated_at before update on public.whatsapp_event_templates
  for each row execute function public.set_updated_at();

-- ── feature flag (ships OFF: nothing changes for customers until a master/dev turns it on) ──────────────────────────
alter table public.settings
  add column if not exists wa_dispatch_v2_enabled boolean not null default false;

-- ── historic optimistic rows stay as history, marked as superseded ───────────────────────────────────────────────────
-- (a no-op when none exist; the probe row has a wa_message_id so it is excluded by construction)
update public.whatsapp_outbox
   set error = 'superseded by retry'
 where direction = 'outbound'
   and status = 'sent'
   and wa_message_id is null
   and retried_at is not null
   and template like 'milestone.%'
   and error is null;
