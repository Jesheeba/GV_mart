-- READ-ONLY snapshot for migration 20261115100400_tasks_customer_outstanding_guard.sql. Run by hand, before and
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
  select 1 from supabase_migrations.schema_migrations where version = '20261115100400'
) as already_registered;

-- The live tasks_select_internal policy text (before: expected post-P3 shape without the
-- ref_type carve-out; after: with it).
select qual from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

select to_regprocedure('public._guard_customer_outstanding_task_ref()') is not null as guard_function_exists;

select exists (
  select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal
) as guard_trigger_exists;
