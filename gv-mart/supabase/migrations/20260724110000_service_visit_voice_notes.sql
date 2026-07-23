-- Build Order Group A / A3 — "product history" notes on a service visit,
-- text and voice, visible to any future technician who services the same
-- product for that customer.
--
-- ── What already existed (STEP 6.1 / Meeting spec D6) ───────────────────────
-- getCustomerHistory() in src/services/technician.ts + JobDetailPage's
-- "Previous service history" card + 20260723120000_technician_customer_
-- history_rls.sql already cover: a technician's free-text `service_visits.
-- notes` from an earlier visit is readable on a later job for the SAME
-- CUSTOMER, even by a different technician (the RLS gap that migration
-- fixed). That part of A3 ("text note … shown to a different technician")
-- was already correct and needed no DB change.
--
-- ── Gap found (fixed here, app-side, no new RLS needed) ─────────────────────
-- getCustomerHistory's query was scoped to `customer_id` only, not
-- `product_id`. A customer with two different products serviced (e.g. a
-- water purifier AND an AMC on a different appliance) would have BOTH
-- products' notes/spares interleaved in "previous service history" on
-- every job, regardless of which product the current ticket is for — noisy
-- at best, and actively misleading when a technician reads a note that was
-- actually about a different appliance. Fixed in
-- src/services/technician.ts's getCustomerHistory by adding an
-- `eq("product_id", productId)` filter (applied only when the current
-- ticket has a product_id — tickets without one keep the previous
-- customer-wide behavior, since there's nothing to scope to). No RLS change
-- needed: 20260723120000's `is_technician_customer` policies already gate
-- access at the customer level; filtering to product_id is a narrower
-- read within that same already-permitted row set, done in the query
-- itself, so this migration carries no policy changes.
--
-- ── Net-new in this migration ────────────────────────────────────────────
-- VOICE notes were not supported at all — `service_visits.notes` is
-- plain text only. This app has no Supabase Storage bucket usage anywhere
-- (before/after photos and both signatures are all stored as base64 data
-- URLs directly in text columns, queued through the existing offline
-- outbox — see PhotoCapture.tsx / SignaturePad.tsx / cacheVisitSignature in
-- technician.ts). `voice_note_url` follows that same established
-- convention for consistency, rather than introducing a new
-- Storage-bucket pattern this codebase doesn't otherwise use.
alter table service_visits
  add column voice_note_url text null;

comment on column service_visits.voice_note_url is
  'Optional on-site voice note captured by the technician, stored as a data: URL (see file header — same convention as before_image_url/after_image_url/tech_sign_url/customer_sign_url, no Storage bucket in use). Surfaced on a later job for the same customer+product via getCustomerHistory(), same RLS as service_visits.notes.';
