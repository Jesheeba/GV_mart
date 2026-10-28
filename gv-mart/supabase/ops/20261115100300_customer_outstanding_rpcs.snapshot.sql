-- READ-ONLY snapshot for migration 20261115100300_customer_outstanding_rpcs.sql. Run by hand, before and
-- after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/to_regclass/to_regtype so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261115100300'
) as already_registered;

select
  to_regprocedure('public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)') is not null as create_reminder_exists,
  to_regprocedure('public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)') is not null as reschedule_reminder_exists,
  to_regprocedure('public.close_customer_outstanding_reminder(uuid)') is not null as close_reminder_exists,
  to_regprocedure('public.cancel_customer_outstanding_reminder(uuid,text)') is not null as cancel_reminder_exists,
  to_regprocedure('public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)') is not null as create_task_exists,
  to_regprocedure('public.close_outstanding_reminders_if_zero(uuid)') is not null as close_if_zero_exists;
