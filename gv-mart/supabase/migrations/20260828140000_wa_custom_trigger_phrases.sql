-- Admin-editable trigger phrases (GV_MART_FINAL_BOT_SPECIFICATION.md,
-- section 5.2) — the one manual dependency of a zero-AI design is that new
-- phrasings need explicit addition; this lets staff add them without a
-- code deploy. Deliberately ADDITIVE, not a replacement for the existing
-- hardcoded TRIGGER_PHRASES/MENU_ITEM_SYNONYMS arrays (whatsapp-status-
-- answers.ts / whatsapp-journeys.ts) — those stay code-reviewed and
-- deployed through the normal process; this table only ever adds MORE
-- phrases on top, merged in at match time. Scoped to the same "safe"
-- categories the design review approved: the 7 status-answer categories
-- + the 6 menu-item synonym slots. Mechanics (menu/cancel/back/expert
-- keyword/language-switch), bare greetings, and payment red-flag phrases
-- are deliberately NOT extensible here — those are navigation/safety
-- primitives that stay code-reviewed only.
create type public.wa_trigger_category as enum (
  'service_ticket',
  'purchase_history',
  'business_address',
  'business_phone',
  'business_hours',
  'emi',
  'product_availability',
  'menu_buy',
  'menu_service',
  'menu_spares',
  'menu_amc',
  'menu_account',
  'menu_expert'
);

create table public.wa_custom_trigger_phrases (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id),
  category public.wa_trigger_category not null,
  phrase text not null,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index wa_custom_trigger_phrases_org_active_idx
  on public.wa_custom_trigger_phrases (org_id, category)
  where is_active;

alter table public.wa_custom_trigger_phrases enable row level security;

-- Same trust tier as settings (the kill switches this feature sits
-- alongside on the Automation page) — any staff member can see what's
-- configured, only master/owner can add or remove a phrase.
create policy wa_custom_trigger_phrases_select_staff on public.wa_custom_trigger_phrases
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy wa_custom_trigger_phrases_write_master on public.wa_custom_trigger_phrases for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
