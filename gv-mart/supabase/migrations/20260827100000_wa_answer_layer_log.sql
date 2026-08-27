-- AI/CRM Answer Layer, Phase 2 — audit log. Every question that reaches the
-- orchestration function gets exactly one row here, regardless of outcome
-- (answered, handed off, or degraded on error) — decision confirmed with
-- the user: log every cannot_answer AND every can_answer:false case
-- explicitly, so Haiku's tool-choice/answer-confidence behavior can be
-- spot-checked later without re-running live traffic.
--
-- Separate table rather than extending whatsapp_outbox.payload (spec's own
-- open question, resolved with the user): whatsapp_outbox is a message
-- transport log (what was sent/received), not a decision-audit log (why the
-- AI answered the way it did, which tool it picked, what raw data it saw).
-- Conflating the two would mean every review of "what did we tell this
-- customer" also has to parse out AI-specific fields that don't apply to
-- template-driven journey replies.
create table public.wa_answer_layer_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  phone text not null,
  question text not null,
  tool_used text, -- null only if round 1 itself failed before a tool_use block was ever returned
  tool_input jsonb,
  tool_result jsonb, -- null for cannot_answer and hard-error outcomes
  can_answer boolean not null default false,
  answer text, -- only set when can_answer = true
  reason text, -- cannot_answer's stated reason, or an error/timeout diagnostic
  latency_ms integer,
  created_at timestamptz not null default now()
);

create index wa_answer_layer_log_org_id_idx on public.wa_answer_layer_log (org_id, created_at desc);
create index wa_answer_layer_log_phone_idx on public.wa_answer_layer_log (phone);

alter table public.wa_answer_layer_log enable row level security;

-- Same shape as whatsapp_outbox's own policies (20260702170000): staff can
-- review it, nothing here is ever written by an authenticated client — the
-- orchestration function inserts via service_role only.
create policy wa_answer_layer_log_select_staff on public.wa_answer_layer_log
  for select using (org_id = public.current_org_id() and public.is_staff());
