-- Technician lifecycle management, Phase 1: admin-created technicians can
-- now capture a home address alongside the existing zone/skills/capacity
-- fields. Informational only (like zone) — not read by the assignment
-- engine, which decides purely by distance/capacity/availability/skill
-- (see 20260730130000_assignment_zone_and_active_fix.sql).

alter table public.technicians
  add column if not exists address text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists pincode text;

comment on column public.technicians.address is 'Technician home/contact address (Technician Lifecycle Mgmt, Phase 1). Informational only.';
comment on column public.technicians.city is 'Technician home/contact city (Technician Lifecycle Mgmt, Phase 1). Informational only.';
comment on column public.technicians.state is 'Technician home/contact state (Technician Lifecycle Mgmt, Phase 1). Informational only.';
comment on column public.technicians.pincode is 'Technician home/contact pincode (Technician Lifecycle Mgmt, Phase 1). Informational only.';
