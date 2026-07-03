-- Phase 10 (Technicians admin + HR/Payroll) — schema additions.
--
-- BuildSpec §5 lists `technicians` as "profile_id fk, skills(text[]), zone,
-- is_on_duty" but the Phase 1 migration (20260701090100_core_tables.sql)
-- never added `zone`. ADM-14's "Add Technician" (edit zone/skills/active
-- status on existing seeded rows — see file header comment, no new auth
-- users provisioned here) and the ENHANCE-tier "zone assignment" bullet
-- both need it, so it's added here rather than touching the owned Phase 1
-- file. `is_active` is likewise new: ADM-14 lists it as a fielded control
-- but no soft-delete/active flag exists yet on `technicians` (only
-- `is_on_duty`, which is a daily attendance-derived toggle, not an
-- employment-status flag).

alter table public.technicians
  add column if not exists zone text,
  add column if not exists is_active boolean not null default true;

create index if not exists technicians_zone_idx on public.technicians (org_id, zone);

comment on column public.technicians.zone is 'Free-text service zone/area assignment (ADM-14). No zone master exists per v2.2 scope guard — plain text field only.';
comment on column public.technicians.is_active is 'Employment/active-roster flag (ADM-14), distinct from is_on_duty which tracks daily attendance state.';
