-- TEMPORARY diagnostic function, service_role only. Returns the raw ACL for
-- the 7 functions targeted by 20260923150000, to verify the REVOKE actually
-- landed (ground truth, not inferred from an anon-key HTTP status). Will be
-- dropped by a follow-up migration once verified.
create or replace function public._audit_check_execute_grants_v2()
returns table(proname text, proacl text)
language sql
security definer
set search_path = public
as $$
  select p.proname, p.proacl::text
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = any(array[
      '_create_complaint_ticket_internal',
      '_submit_customer_enquiry_internal',
      '_auto_assign_next_ticket_to_technician',
      'technician_attributed_sales',
      'technician_attributed_revenue',
      'technician_finder_conversions',
      'technician_late_hours',
      'wa_get_amc_status',
      'create_complaint_ticket'
    ]);
$$;

revoke execute on function public._audit_check_execute_grants_v2() from public, anon, authenticated;
grant execute on function public._audit_check_execute_grants_v2() to service_role;
