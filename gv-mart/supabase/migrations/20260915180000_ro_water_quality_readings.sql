-- Technician-recorded water quality readings during an RO service visit.
-- Distinct from tds_before/tds_after above (which measure filter
-- effectiveness across a single visit's cleaning) — these capture the
-- property's general water profile (TDS/PH/Hardness + source), which the
-- customer profile page also surfaces as a "Measured" reading alongside the
-- regional district-level estimate (water_quality_reference).
create type water_source_type as enum ('corporation', 'borewater', 'other');

alter table ro_checklists
  add column water_tds_ppm numeric(6, 2),
  add column water_ph numeric(4, 2),
  add column water_hardness_ppm numeric(6, 2),
  add column water_source water_source_type,
  add column water_source_other text,
  -- Dynamic "extra field" capability — bounded jsonb array of {label, value}
  -- pairs, same convention as service_visits.evidence_photo_urls and
  -- products.feature_bullets (see 20260804090000_product_media_and_attributes.sql
  -- for this codebase's documented anti-EAV stance): no DB-level schema,
  -- runtime-guarded on the client, never a generic key-value child table.
  add column water_extra_readings jsonb not null default '[]'::jsonb;
