-- Product Lifecycle & Automated Service Reminder System — Drop 2, migration 3/3.
-- Standard release-wide anon-exposure sweep (hard rule), same pattern as Drop 1's.

revoke all on function
  public.lifecycle_mark_followup_contacted(uuid, text),
  public.lifecycle_snooze_followup(uuid, date),
  public.lifecycle_create_service_request(uuid),
  public.get_customer_installed_products(uuid),
  public.get_customer_replacement_history(uuid),
  public.get_lifecycle_followups_for_sales(uuid)
from public, anon;

revoke all on public.lifecycle_followup_actions from public, anon;

select
  n.nspname, p.proname, pg_catalog.pg_get_userbyid(p.proowner) as owner,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'lifecycle_mark_followup_contacted', 'lifecycle_snooze_followup',
    'lifecycle_create_service_request', 'get_customer_installed_products',
    'get_customer_replacement_history', 'get_lifecycle_followups_for_sales'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');
