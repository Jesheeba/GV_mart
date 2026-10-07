-- HELD (not applied, not in migrations/): closes the anon/authenticated exposure of the
-- lead helper functions. See docs/security-note-anon-lead-functions.md and the caller proof in
-- supabase/tests/lead_helpers_revoke.test.sql. Move into migrations/ only after owner approval.
--
-- Callers (checked in live function bodies and in code):
--   _find_recent_open_lead  <- _whatsapp_lead_upsert, book_service_ticket, request_callback,
--                              _submit_customer_enquiry_internal   (ALL SECURITY DEFINER)
--   _whatsapp_lead_upsert   <- wa_create_lead (SECURITY DEFINER, service role from the webhooks),
--                              simulate_inbound_whatsapp (was SECURITY INVOKER: staff, in-app test panel)
--   generate_enquiry_lead   <- src/lib/offline/sync.ts (technician; does NOT call the helpers)
-- A definer function runs as its owner, so revoking client roles does not affect these callers.
-- The only invoker caller is simulate_inbound_whatsapp, which becomes SECURITY DEFINER
-- (ALTER keeps its body; its own org-match + is_staff() gate reads auth.uid(), unchanged).

alter function public.simulate_inbound_whatsapp(uuid, text, text) security definer;
alter function public.simulate_inbound_whatsapp(uuid, text, text) set search_path = public;

revoke all on function public._whatsapp_lead_upsert(uuid, text, public.enquiry_type, text) from public, anon, authenticated;
revoke all on function public._find_recent_open_lead(uuid, uuid, text, interval) from public, anon, authenticated;

-- gated already (technician / staff check) but pointless for anonymous callers
revoke all on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text) from public, anon;
revoke all on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text, uuid) from public, anon;
revoke all on function public.simulate_inbound_whatsapp(uuid, text, text) from public, anon;

grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text) to authenticated;
grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text, uuid) to authenticated;
grant execute on function public.simulate_inbound_whatsapp(uuid, text, text) to authenticated;

-- PROPOSALS ONLY (not in this file):
--  * defence in depth inside _whatsapp_lead_upsert: raise unless auth.role() = 'service_role' or is_staff();
--  * rate limit: skip the lead_activities insert when the same mobile already wrote >N activities in 10 minutes;
--  * organisation check: the webhooks already resolve p_org_id server-side from the WhatsApp business number, never from the message.
