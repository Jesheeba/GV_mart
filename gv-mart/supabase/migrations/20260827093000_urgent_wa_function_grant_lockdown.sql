-- URGENT SECURITY FIX — discovered 2026-08-27 while smoke-testing the new
-- Answer Layer RPCs (20260827090000). Every wa_*/_wa_* function in this
-- codebase was created with NO explicit GRANT statement. Every comment
-- next to them claims "Intentionally NOT granted to authenticated —
-- service_role only" — but that was never actually enforced: Postgres
-- grants EXECUTE to the PUBLIC pseudo-role by default on CREATE FUNCTION
-- (unlike table access, which RLS gates), and every real role — including
-- anon and authenticated — is implicitly a member of PUBLIC. These are all
-- SECURITY DEFINER, so RLS provides no backstop either; the function-level
-- GRANT was the only protection ever intended, and it was silently absent
-- since the day each function was created.
--
-- Confirmed empirically (service-role smoke test + a direct anon-key call):
-- wa_get_amc_status, wa_identify_customer, and wa_get_conversation all
-- returned real customer data (name, phone, tickets, AMC/warranty, active
-- conversation state) to a request authenticated with ONLY the public,
-- non-secret, client-bundled anon key — no login, no session, nothing.
-- pg_proc/has_function_privilege confirms the same exposure on every
-- wa_*/_wa_* function that exists, including WRITE paths:
-- wa_create_service_ticket, wa_create_lead, wa_create_spare_enquiry, and
-- wa_log_quote_reply mean anyone holding the anon key could have created
-- fake tickets/leads/enquiries or forged a supplier quote reply for any
-- phone number, and wa_save_conversation_step means anyone could have
-- overwritten another phone's live bot conversation state.
--
-- Fix: revoke the default PUBLIC grant on every wa_*/_wa_* function (this
-- also revokes it from anon/authenticated/service_role, since none of them
-- ever had an INDEPENDENT grant — all access was riding on the PUBLIC
-- default), then explicitly re-grant EXECUTE to service_role only, the
-- role Edge Functions actually authenticate as. One exception:
-- _wa_normalize_phone was the sole function with a pre-existing, presumably
-- deliberate `grant ... to authenticated` (20260819120000) — it's a pure,
-- stateless phone-string formatter with no table access at all, so no
-- security exposure either way; not found in use anywhere in src/, but
-- preserved as-is rather than silently narrowed, since removing an
-- intentional-looking grant this function's own migration was not asked
-- for and isn't what this fix is about.
do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'wa\_%' or p.proname like '\_wa\_%')
  loop
    execute format('revoke execute on function public.%I(%s) from public', r.proname, r.args);
    execute format('grant execute on function public.%I(%s) to service_role', r.proname, r.args);

    if r.proname = '_wa_normalize_phone' then
      execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
    end if;
  end loop;
end;
$$;

-- Belt-and-suspenders: any FUTURE function created in the public schema by
-- the migration role no longer gets an implicit PUBLIC grant either, so
-- this exact gap can't reopen the next time a service-role-only function
-- (wa_* or otherwise) is added without its own explicit grant line.
alter default privileges in schema public revoke execute on functions from public;
