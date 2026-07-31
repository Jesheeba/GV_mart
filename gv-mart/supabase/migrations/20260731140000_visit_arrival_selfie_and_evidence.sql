-- Technician Module Audit, Task 6 — the base44/customer requirement asks for
-- an arrival selfie + damaged/replaced/installed-parts evidence on top of
-- the existing before/after photos. Storage stays exactly as it already
-- works for every other on-site photo/signature (base64 data: URL in a
-- Postgres column — deliberate, documented offline-first choice, see
-- 20260724110000_service_visit_voice_notes.sql's header) — this migration
-- only adds the two missing columns, no new storage backend.
alter table public.service_visits
  add column arrival_selfie_url text,
  add column evidence_photo_urls jsonb not null default '[]';
