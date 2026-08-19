-- WhatsApp Integration, Phase 1 — real webhook foundation, on top of the
-- existing ADM-23 simulation (whatsapp_outbox, send_whatsapp_stub,
-- simulate_inbound_whatsapp, automation_flows). Additive only — no existing
-- table's semantics change.

-- Conversation state (decision #1: Postgres, not the transport layer) — one
-- open row per phone number driving the Phase 2b journey state machine.
-- `journey`/`step`/`status` are free text + check, not new enums, matching
-- the existing whatsapp_outbox.direction/status convention — new journeys
-- and steps are a Phase 2b/5 code concern, not a schema migration.
create table public.whatsapp_conversations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  phone text not null,
  customer_id uuid references public.customers (id) on delete set null,
  journey text,
  step text,
  collected jsonb not null default '{}'::jsonb,
  status text not null default 'active' check (status in ('active', 'completed', 'expired', 'handed_off')),
  expires_at timestamptz,
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One open conversation per phone at a time — wa_get_conversation/
-- wa_save_conversation_step (next migration) rely on this to find "the"
-- active conversation for a phone without an extra status filter racing a
-- concurrent webhook delivery.
create unique index whatsapp_conversations_open_per_phone_idx
  on public.whatsapp_conversations (org_id, phone)
  where status = 'active';

create index whatsapp_conversations_org_id_idx on public.whatsapp_conversations (org_id, last_message_at desc);
create index whatsapp_conversations_customer_id_idx on public.whatsapp_conversations (customer_id);

alter table public.whatsapp_conversations enable row level security;

create policy whatsapp_conversations_select_staff on public.whatsapp_conversations
  for select using (org_id = public.current_org_id() and public.is_staff());

-- Maps a Meta WABA phone_number_id (from the webhook payload) to a tenant —
-- decision #6: this deployment has one organizations row today, but the
-- webhook resolves org_id through this table rather than hardcoding, so a
-- second tenant is a data row, not a code change. Config-only: no rows
-- exist until Phase 0's Meta business verification produces a real
-- phone_number_id, and the webhook falls back to the sole organization row
-- when this table is empty (see whatsapp-webhook Edge Function).
create table public.whatsapp_business_numbers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  phone_number_id text not null unique,
  display_phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.whatsapp_business_numbers enable row level security;

create policy whatsapp_business_numbers_select_staff on public.whatsapp_business_numbers
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy whatsapp_business_numbers_write_ops on public.whatsapp_business_numbers for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- Decision #2: extend whatsapp_outbox rather than add a parallel
-- whatsapp_messages table — it already has the right shape (direction,
-- payload, status). It's missing exactly the piece the proposal calls the
-- #1 real-world failure mode:
--   wa_message_id — Meta's own message id. Unique (nullable, since rows
--     logged by the pre-existing send_whatsapp_stub/simulate_inbound_
--     whatsapp paths never had one) so the webhook can insert-or-skip on a
--     retried delivery instead of creating a duplicate ticket/lead.
--   type — text/template/interactive/media, so the Phase 4 ops surface and
--     Phase 2b journey code know how to render/replay a row.
--   error — set on a failed real send; surfaces in the Phase 4 failed-send log.
alter table public.whatsapp_outbox
  add column wa_message_id text,
  add column type text,
  add column error text;

create unique index whatsapp_outbox_wa_message_id_idx
  on public.whatsapp_outbox (wa_message_id)
  where wa_message_id is not null;

-- Decision #7 (accepted risk, stated explicitly): unused by any RPC yet.
-- wa_identify_customer trusts "message arrived from phone X" as proof of
-- being customer X. This column is the seam for an OTP gate later, if that
-- trust level stops being acceptable — see the plan doc for the full
-- trade-off.
alter table public.customers
  add column phone_verified boolean not null default false;
