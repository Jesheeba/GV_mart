-- Phase 1 of GV_Mart_Technician_Assignment_Logic_Change.md: "turn on the
-- data the engine needs" for the technician-assignment rework. No
-- assignment-logic behaviour change yet (that's Phase 2/3) — this migration
-- only adds columns/tables and a data-population trigger.
--
-- Scope decisions made with the owner before writing this (see the spec's
-- own "Open decisions" section + this project's v2.2 scope guard):
--   - 1.1 Skill: technicians.skills / technicians.zone are ALREADY editable
--     (TechnicianDetailPage.tsx) — no new UI needed there. What's missing is
--     a ticket-level required_skill. products.category is the existing
--     brand_category enum ('ro'|'ac'|'inverter'|'battery',
--     20260701090000_extensions_and_enums.sql:8), which already matches
--     technicians.skills' vocabulary exactly (TechnicianDetailPage.tsx's
--     SKILL_OPTIONS), so required_skill is simply copied from the ticket's
--     product at insert time — see the trigger below.
--   - 1.2 Zone: technicians.zone already exists. Ticket-side zone resolves
--     via a plain manual `addresses.zone` tag (admin-set per address,
--     matching the same free-text convention technicians.zone already
--     uses) — deliberately NOT a PIN->zone mapping master (that would be
--     the blocked "zone/area master").
--   - 1.3 Capacity: estimated_duration_minutes is sourced from a lightweight
--     per-ticket-type settings default (default_duration_*_minutes), NOT
--     the blocked "SOP-time master screen" — that item stays declined per
--     the 2026-07-08 decision (see gv-mart-v22-scope-guard memory).
--   - 1.4 Roster/leave: technician_availability is genuinely new (built as
--     specified) — separate from is_on_duty (today's attendance only);
--     this is forward-looking planning data for Phase 6.
--   - 1.5 Customer availability window: appointments.available_from/to are
--     plain nullable columns here; wiring them into the booking flows'
--     RPC signatures is a separate migration (kept out of this one to avoid
--     touching create_complaint_ticket/book_service_ticket's large bodies
--     in the same change as new schema).

-- ── 1.1 Skill: ticket-level required_skill ──────────────────────────────
alter table public.service_tickets add column if not exists required_skill text;

-- ── 1.2 Zone: manual per-address tag ─────────────────────────────────────
alter table public.addresses add column if not exists zone text;
create index if not exists addresses_zone_idx on public.addresses (org_id, zone);

-- ── 1.3 Capacity: per-technician daily capacity + per-ticket-type defaults ──
alter table public.technicians
  add column if not exists daily_capacity_minutes integer not null default 480
    check (daily_capacity_minutes > 0);

alter table public.settings
  add column if not exists default_duration_paid_minutes integer not null default 45
    check (default_duration_paid_minutes > 0),
  add column if not exists default_duration_warranty_minutes integer not null default 45
    check (default_duration_warranty_minutes > 0),
  add column if not exists default_duration_amc_minutes integer not null default 30
    check (default_duration_amc_minutes > 0),
  add column if not exists default_duration_installation_minutes integer not null default 90
    check (default_duration_installation_minutes > 0);

alter table public.service_tickets add column if not exists estimated_duration_minutes integer;

-- ── Data-population trigger (1.1 + 1.3 together): every newly-inserted
-- ticket gets required_skill (from its product's category) and
-- estimated_duration_minutes (from the org's per-type settings default)
-- filled in automatically, UNLESS the inserting caller already supplied a
-- value. This deliberately avoids touching the ~6 existing RPC functions
-- that insert into service_tickets (create_complaint_ticket,
-- book_service_ticket, register_product_via_qr, create_sale, sell_amc_plan,
-- renew_amc_plan) — safer than reproducing their large bodies verbatim
-- just to add two columns, and covers every insert path (present and
-- future) uniformly. ──────────────────────────────────────────────────────
create or replace function public._service_tickets_derive_skill_and_duration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings settings;
begin
  if new.required_skill is null and new.product_id is not null then
    select p.category::text into new.required_skill
    from public.products p
    where p.id = new.product_id;
  end if;

  if new.estimated_duration_minutes is null then
    select * into v_settings from public.settings where org_id = new.org_id;
    if v_settings is not null then
      new.estimated_duration_minutes := case new.type
        when 'paid' then v_settings.default_duration_paid_minutes
        when 'warranty' then v_settings.default_duration_warranty_minutes
        when 'amc' then v_settings.default_duration_amc_minutes
        when 'installation' then v_settings.default_duration_installation_minutes
        else v_settings.default_duration_paid_minutes
      end;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists service_tickets_derive_skill_and_duration on public.service_tickets;
create trigger service_tickets_derive_skill_and_duration
  before insert on public.service_tickets
  for each row execute function public._service_tickets_derive_skill_and_duration();

-- ── 1.4 Roster/leave: technician_availability (forward-looking planning,
-- distinct from is_on_duty which is today-only attendance) ─────────────────
create table if not exists public.technician_availability (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  technician_id uuid not null references public.technicians(id) on delete cascade,
  date date not null,
  status text not null check (status in ('working', 'leave')),
  shift_start time,
  shift_end time,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (technician_id, date)
);

create index if not exists technician_availability_org_date_idx
  on public.technician_availability (org_id, date);

alter table public.technician_availability enable row level security;

create policy technician_availability_staff_all on public.technician_availability
  for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy technician_availability_select_own on public.technician_availability
  for select
  using (technician_id = public.current_technician_id());

grant select, insert, update, delete on public.technician_availability to authenticated;

-- ── 1.5 Customer availability window (schema only — see note above) ───────
alter table public.appointments add column if not exists available_from time;
alter table public.appointments add column if not exists available_to time;
