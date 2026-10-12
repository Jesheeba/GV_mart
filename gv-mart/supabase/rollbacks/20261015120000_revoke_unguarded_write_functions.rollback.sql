-- Rollback for 20261015120000_revoke_unguarded_write_functions.sql: restores the ACLs saved before the change
-- (Desktop\GV_mart_acl_backup_2026-10-12_unguarded_write_functions.json). Re-opens the anon path: only use if a legitimate
-- caller broke. Three functions had explicit anon + authenticated grants, the rest PUBLIC only.
do $rb$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('_auto_assign_ticket_internal', '_sale_create_line_invoice', '_create_po_from_winning_quote')
  loop
    execute format('grant execute on function %s to public, anon, authenticated', r.sig);
  end loop;
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('_create_po_payment_reminder_task', '_resolve_purchase_quote_requests_core',
                         'wa_resolve_purchase_quote_requests', 'advance_recurring_tasks', 'open_monthly_quote_requests',
                         'run_rental_billing', 'wa_escalate_overdue_po_payment_reminders')
  loop
    execute format('grant execute on function %s to public', r.sig);
  end loop;
end
$rb$;
-- create_purchase_order back to SECURITY INVOKER (same body as the F-08 migration)
alter function public.create_purchase_order(uuid, uuid, jsonb) security invoker;
alter function public.create_purchase_order(uuid, uuid, jsonb) reset search_path;
