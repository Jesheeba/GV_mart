-- Cleanup: drop stale overloads left behind by append-only trailing-param
-- migrations that used plain CREATE OR REPLACE instead of DROP + CREATE
-- (Postgres only truly "replaces" when the parameter list is unchanged —
-- appending a new trailing param, even a DEFAULT one, creates a second
-- distinct overload instead). Found while investigating a live PGRST203
-- "could not choose the best candidate function" error surfaced during
-- Phase 2a testing.
--
-- Confirmed via direct pg_catalog query and a grep of every real call site
-- in src/: each of these three RPCs has exactly one caller, and that caller
-- always supplies the full current trailing-param set by name. PostgREST's
-- named-argument resolution excludes any candidate missing a supplied
-- parameter name, so every real caller already deterministically resolves
-- to the newest (kept) overload today — dropping the stale ones changes
-- nothing about what any existing caller resolves to.

-- create_complaint_ticket: keep the 17-arg version (current live wrapper,
-- Phase 2a's _create_complaint_ticket_internal delegate); drop 14/15/16.
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid
);
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid
);
drop function if exists public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text
);

-- submit_customer_enquiry: keep the 7-arg jsonb-items version (current live
-- wrapper, Phase 2a's _submit_customer_enquiry_internal delegate); drop the
-- 5-arg pre-address/pre-items version.
drop function if exists public.submit_customer_enquiry(
  uuid, text, enquiry_type, text, text
);

-- book_service_ticket: keep the 11-arg version (current, has
-- p_complaint_type_id); drop the 10-arg version.
drop function if exists public.book_service_ticket(
  uuid, uuid, uuid, uuid, uuid, text, text, priority_level, date, jsonb
);
