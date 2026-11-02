-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 8/8.
-- Standard release-wide anon-exposure sweep (hard rule). This project has a
-- known recurring default-privileges leak (memory:
-- gv_mart_default_privileges_anon_execute_leak — new functions/tables can
-- auto-grant EXECUTE/SELECT to anon). Explicitly re-revoke on every object
-- this feature created, belt-and-suspenders on top of each migration's own
-- revoke statements.

revoke all on function
  public._lifecycle_add_interval(date, integer, text),
  public.create_installed_product(uuid, uuid, date, uuid, boolean),
  public.correct_installation_date(uuid, date),
  public.apply_updated_schedule_preview(uuid),
  public.apply_updated_schedule(uuid),
  public.record_part_replacement(uuid, date, uuid, uuid, text),
  public.get_customer_due_parts(uuid),
  public.log_installed_products_for_invoice(uuid, uuid, jsonb),
  public.generate_lifecycle_reminders(timestamptz),
  public.lifecycle_reminders_cron_tick(text)
from public, anon;

revoke all on
  public.product_lifecycle_configs,
  public.product_spare_schedules,
  public.customer_installed_products,
  public.customer_part_schedules,
  public.part_replacement_history,
  public.lifecycle_reminder_events,
  public.lifecycle_expiry_reminder_events
from public, anon;

-- Verification query (read-only, logged to the apply output for the record):
-- lists any of the above objects still reachable by anon/public after the
-- revokes above — expected to return zero rows.
select
  n.nspname, p.proname, pg_catalog.pg_get_userbyid(p.proowner) as owner,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    '_lifecycle_add_interval', 'create_installed_product', 'correct_installation_date',
    'apply_updated_schedule_preview', 'apply_updated_schedule', 'record_part_replacement',
    'get_customer_due_parts', 'log_installed_products_for_invoice',
    'generate_lifecycle_reminders', 'lifecycle_reminders_cron_tick'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');
