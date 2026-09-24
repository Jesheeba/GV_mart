-- Production-readiness audit (2026-09-23) found 7 more functions still
-- carrying the same pre-v2 default-ACL leak that 20260827094500 fixed for
-- wa_*/_wa_* functions: all predate that migration, and none match its
-- name filter (wa\_% / \_wa\_%), so the durable `alter default privileges`
-- override added there never touched them. Confirmed via pg_proc.proacl
-- that each still has independent, explicit anon=X/postgres and
-- authenticated=X/postgres grants from the original bootstrap default.
--
-- All 7 are, by design, only ever called internally by another
-- SECURITY DEFINER function owned by the same role (postgres) — confirmed
-- by grepping both supabase/migrations and src/ for direct callers:
--   * _create_complaint_ticket_internal / _submit_customer_enquiry_internal
--     — only called from their checked public wrappers
--     (create_complaint_ticket / submit_customer_enquiry, both is_ops_staff()-
--     gated) and from the wa_* service-role wrappers, never from the
--     frontend or an Edge Function directly.
--   * _auto_assign_next_ticket_to_technician — only called from triggers/
--     other internal assignment-engine functions, never via supabase.rpc()
--     from src/ or supabase/functions/.
--   * technician_attributed_sales/_revenue, technician_finder_conversions,
--     technician_late_hours — only ever called from other internal HR/
--     reward-computation functions (hr_functions.sql, sales_income_attribution.sql,
--     finder_credit_functions.sql, reward_candidates_v2.sql), never directly
--     from the frontend (confirmed: zero matches in src/ or supabase/functions/
--     other than the generated type in database.ts).
--
-- None of the 7 need anon or authenticated EXECUTE at all — unlike
-- _wa_normalize_phone in the v2 migration, there is no legitimate direct
-- caller in either role for any of these. Using v2's same proven technique
-- (explicit per-role REVOKE by name, not by PUBLIC) rather than repeating
-- the original no-op mistake.
do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = any(array[
        '_create_complaint_ticket_internal',
        '_submit_customer_enquiry_internal',
        '_auto_assign_next_ticket_to_technician',
        'technician_attributed_sales',
        'technician_attributed_revenue',
        'technician_finder_conversions',
        'technician_late_hours'
      ])
  loop
    execute format('revoke execute on function public.%I(%s) from anon', r.proname, r.args);
    execute format('revoke execute on function public.%I(%s) from authenticated', r.proname, r.args);
  end loop;
end;
$$;
