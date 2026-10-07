-- Rollback for 20261010130000_revoke_anon_lead_helpers.sql: restores the exact previous state
-- (ACL {=X, postgres, anon, authenticated, service_role} on all five functions; simulate_inbound_whatsapp
-- SECURITY INVOKER with no function-level search_path).
alter function public.simulate_inbound_whatsapp(uuid, text, text) security invoker;
alter function public.simulate_inbound_whatsapp(uuid, text, text) reset search_path;

grant execute on function public._whatsapp_lead_upsert(uuid, text, public.enquiry_type, text) to public, anon, authenticated;
grant execute on function public._find_recent_open_lead(uuid, uuid, text, interval) to public, anon, authenticated;
grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text) to public, anon, authenticated;
grant execute on function public.generate_enquiry_lead(uuid, uuid, text, text, public.enquiry_type, text, uuid) to public, anon, authenticated;
grant execute on function public.simulate_inbound_whatsapp(uuid, text, text) to public, anon, authenticated;
