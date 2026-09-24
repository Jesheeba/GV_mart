-- Follow-up to 20260923150000: that migration revoked EXECUTE from anon and
-- authenticated directly on the 7 target functions, but anon-key calls
-- against them STILL SUCCEEDED after applying it. Root-caused via a
-- temporary diagnostic RPC comparing pg_proc.proacl directly: these 7
-- functions still carried an explicit `=X/postgres` (PUBLIC) grant, which
-- anon inherits as a PUBLIC member regardless of any direct per-role revoke.
-- The already-fixed wa_get_amc_status (from 20260827094500) has NO PUBLIC
-- entry in its ACL at all, confirming PUBLIC is the actual mechanism to
-- close here, not something already covered by that migration's technique.
-- Repeating the same by-name REVOKE loop, now targeting PUBLIC as well as
-- anon/authenticated (anon/authenticated revokes are redundant with
-- 20260923150000 but harmless/idempotent; included so this migration is a
-- complete, standalone fix).
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
    execute format('revoke execute on function public.%I(%s) from public', r.proname, r.args);
    execute format('revoke execute on function public.%I(%s) from anon', r.proname, r.args);
    execute format('revoke execute on function public.%I(%s) from authenticated', r.proname, r.args);
  end loop;
end;
$$;
