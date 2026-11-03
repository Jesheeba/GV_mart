-- Water & household step (2026-11-03): admin Customer form gets a new
-- review step capturing the primary address's water source/quality plus the
-- household's health condition, alongside the existing family-members list.
-- Mirrors 20261103090000_address_full_address_field.sql — nullable, additive
-- columns, no backfill, no RPC change (create_customer_with_details is left
-- untouched; a brand-new customer's primary address gets these written as a
-- small follow-up update, same pattern as setAddressZone).
alter table public.addresses add column if not exists water_source text;
alter table public.addresses add column if not exists water_tds integer;
alter table public.addresses add column if not exists water_ph numeric;
alter table public.addresses add column if not exists health_condition text;

comment on column public.addresses.water_source is
  'Added 2026-11-03 — free-text water source (e.g. Corporation, Borewater), captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.water_tds is
  'Added 2026-11-03 — measured TDS in ppm, captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.water_ph is
  'Added 2026-11-03 — measured pH, captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.health_condition is
  'Added 2026-11-03 — free-text household health condition note, captured on the Water & household step of the admin Customer form.';
