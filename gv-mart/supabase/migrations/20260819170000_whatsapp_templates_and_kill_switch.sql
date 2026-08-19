-- WhatsApp Integration, Phase 3 — templates, kill switch, and wiring the
-- existing milestone triggers to render through a real template instead of
-- a placeholder string tag.

-- ── Templates ────────────────────────────────────────────────────────────
-- `variable_map` maps Meta's numbered placeholders ({{1}}, {{2}}, ...) to
-- this app's semantic field names (e.g. {"1": "customer_name", "2":
-- "ticket_ref"}) — Meta template bodies use position, our data uses names;
-- this is the translation between the two. `body` holds the template text
-- itself so it can be rendered locally (stub/log mode, or before Meta
-- approval) without waiting on Meta's template library API.
create table public.whatsapp_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  category text not null default 'utility' check (category in ('utility', 'marketing')),
  approval_status text not null default 'pending' check (approval_status in ('pending', 'approved', 'rejected')),
  body text not null,
  variable_map jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);

create index whatsapp_templates_org_id_idx on public.whatsapp_templates (org_id);

alter table public.whatsapp_templates enable row level security;

create policy whatsapp_templates_select_staff on public.whatsapp_templates
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy whatsapp_templates_write_ops on public.whatsapp_templates for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_whatsapp_templates after insert or update or delete on public.whatsapp_templates for each row execute function public.audit_master_change();

-- ── Kill switch ──────────────────────────────────────────────────────────
-- Checked FIRST thing in the whatsapp-webhook Edge Function, before any
-- other logic — same is_active-boolean convention automation_flows already
-- uses. Defaults true: with the transport still stub/log-only (decision
-- #5, still open), "on" costs nothing real to ship — the switch exists as
-- the off-ramp for once a real provider is wired in.
alter table public.settings
  add column if not exists whatsapp_bot_enabled boolean not null default true;

-- ── Template rendering ───────────────────────────────────────────────────
-- Single choke point every milestone trigger below goes through. Looks up
-- the named template, substitutes each {{n}} placeholder using variable_map
-- to resolve n -> a key in p_vars. Returns found:false (not an error) when
-- no template row exists yet for that name — callers fall back to their
-- pre-Phase-3 placeholder behavior, so this doesn't block on Meta template
-- approval (Phase 0) to be useful.
create or replace function public._wa_render_template(p_org_id uuid, p_name text, p_vars jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tpl whatsapp_templates;
  v_body text;
  v_pair record;
begin
  select * into v_tpl from public.whatsapp_templates where org_id = p_org_id and name = p_name limit 1;
  if v_tpl.id is null then
    return jsonb_build_object('found', false);
  end if;

  v_body := v_tpl.body;
  for v_pair in select key, value from jsonb_each_text(coalesce(v_tpl.variable_map, '{}'::jsonb))
  loop
    v_body := replace(v_body, '{{' || v_pair.key || '}}', coalesce(p_vars ->> v_pair.value, ''));
  end loop;

  return jsonb_build_object('found', true, 'body', v_body, 'template_id', v_tpl.id, 'approval_status', v_tpl.approval_status);
end;
$$;

-- ── Milestone triggers: render through a template when one exists ────────
-- Bodies are the live versions from 20260702170100_automation_purchase_
-- functions.sql, with one addition each: look up the matching template by
-- name (milestone.<event>) and, if found, put its rendered body in
-- payload.body alongside the existing structured fields — nothing existing
-- removed, so any caller reading the old payload shape is unaffected.
create or replace function public._milestone_ticket_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_milestone text;
  v_rendered jsonb;
begin
  if tg_op = 'INSERT' then
    v_milestone := 'booked';
  elsif tg_op = 'UPDATE' and new.status = 'assigned' and old.status is distinct from 'assigned' then
    v_milestone := 'assigned';
  elsif tg_op = 'UPDATE' and new.status = 'completed' and old.status is distinct from 'completed' then
    v_milestone := 'completed';
  else
    return new;
  end if;

  select id, mobile, name into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    v_rendered := public._wa_render_template(
      new.org_id, 'milestone.' || v_milestone,
      jsonb_build_object('customer_name', v_customer.name, 'ticket_id', new.id::text, 'complaint', new.name_of_complaint)
    );
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, type, payload, ref_type, ref_id, status)
    values (
      new.org_id, 'outbound', v_customer.mobile, v_customer.id, v_milestone, 'milestone.' || v_milestone,
      case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
      jsonb_build_object('ticket_id', new.id, 'type', new.type) || case when (v_rendered ->> 'found')::boolean then jsonb_build_object('body', v_rendered ->> 'body') else '{}'::jsonb end,
      'service_ticket', new.id, 'sent'
    );
  end if;

  return new;
end;
$$;

create or replace function public._milestone_visit_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_ticket record;
  v_rendered jsonb;
begin
  select id, customer_id into v_ticket from public.service_tickets where id = new.ticket_id;
  if v_ticket.customer_id is null then
    return new;
  end if;
  select id, mobile, name into v_customer from public.customers where id = v_ticket.customer_id;
  if v_customer.id is not null then
    v_rendered := public._wa_render_template(
      new.org_id, 'milestone.on_the_way',
      jsonb_build_object('customer_name', v_customer.name, 'ticket_id', new.ticket_id::text)
    );
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, type, payload, ref_type, ref_id, status)
    values (
      new.org_id, 'outbound', v_customer.mobile, v_customer.id, 'on_the_way', 'milestone.on_the_way',
      case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
      jsonb_build_object('ticket_id', new.ticket_id, 'technician_id', new.technician_id) || case when (v_rendered ->> 'found')::boolean then jsonb_build_object('body', v_rendered ->> 'body') else '{}'::jsonb end,
      'service_visit', new.id, 'sent'
    );
  end if;
  return new;
end;
$$;

create or replace function public._milestone_invoice_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_rendered jsonb;
begin
  select id, mobile, name into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    v_rendered := public._wa_render_template(
      new.org_id, 'milestone.invoice',
      jsonb_build_object('customer_name', v_customer.name, 'invoice_id', new.id::text, 'total', new.total::text)
    );
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, type, payload, ref_type, ref_id, status)
    values (
      new.org_id, 'outbound', v_customer.mobile, v_customer.id, 'invoice', 'milestone.invoice',
      case when (v_rendered ->> 'found')::boolean then 'template' else 'text' end,
      jsonb_build_object('invoice_id', new.id, 'total', new.total, 'type', new.type) || case when (v_rendered ->> 'found')::boolean then jsonb_build_object('body', v_rendered ->> 'body') else '{}'::jsonb end,
      'invoice', new.id, 'sent'
    );
  end if;
  return new;
end;
$$;

-- Triggers already exist (20260702170100) and point at these same function
-- names — CREATE OR REPLACE above is enough, no DROP/CREATE TRIGGER needed.
