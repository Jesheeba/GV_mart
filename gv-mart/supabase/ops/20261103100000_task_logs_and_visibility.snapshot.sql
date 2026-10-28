-- READ-ONLY snapshot for migration 20261103100000_task_logs_and_visibility.sql (P3). Run by hand, before
-- and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including before
-- 11:00 IST. Every reference to an object this migration creates is guarded with to_regprocedure/
-- to_regclass so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Row count and fingerprint of the table this migration's correctness depends on (REAL orgs only, same
-- formula as the apply script's pre/post check). Run before and after; must be byte-identical in both
-- runs since this migration touches no table rows.
select
  (select count(*) from public.tasks t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as tasks_count,
  md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
             from public.tasks t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as tasks_fingerprint;

-- Prerequisites: P1a and P1b must already be registered, and current_technician_id() must already carry
-- the post-P1b body (references is_active).
select
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261101100000') as p1a_registered,
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261101110000') as p1b_registered,
  case when to_regprocedure('public.current_technician_id()') is null then null
       else position('is_active' in pg_get_functiondef(to_regprocedure('public.current_technician_id()'))) > 0 end as current_technician_id_is_post_p1b;

-- Whether supabase_migrations.schema_migrations already has P3's own version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261103100000'
) as already_registered;

-- Current live USING clause of the tasks_select_internal policy -- expect the pre-P3 clause (no
-- assignee/assigned_by restriction) before the apply, and the narrowed clause after.
select pol.polname, pg_get_expr(pol.polqual, pol.polrelid) as using_clause
from pg_policy pol
where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_select_internal';

-- Whether each of the 3 brand-new functions and the new table already exist (expect false/NULL before,
-- true/not-null after).
select
  to_regprocedure('public._trg_task_log_client_insert()') is not null as trg_task_log_client_insert_exists,
  to_regprocedure('public._trg_task_log_immutable()') is not null as trg_task_log_immutable_exists,
  to_regprocedure('public._trg_task_log_changes()') is not null as trg_task_log_changes_exists,
  to_regclass('public.task_logs') is not null as task_logs_table_exists;

-- Privilege/RLS state of task_logs, guarded against the table being absent.
select
  case when to_regclass('public.task_logs') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.task_logs')) end as task_logs_rls_enabled,
  case when to_regclass('public.task_logs') is null then null
       else has_table_privilege('authenticated', 'public.task_logs', 'SELECT') end as task_logs_select_by_authenticated,
  case when to_regclass('public.task_logs') is null then null
       else has_table_privilege('authenticated', 'public.task_logs', 'INSERT') end as task_logs_insert_by_authenticated,
  case when to_regclass('public.task_logs') is null then null
       else has_table_privilege('anon', 'public.task_logs', 'SELECT') end as task_logs_select_by_anon,
  case when to_regprocedure('public._trg_task_log_client_insert()') is null then null
       else has_function_privilege('anon', 'public._trg_task_log_client_insert()', 'execute') end as trg_task_log_client_insert_anon,
  case when to_regprocedure('public._trg_task_log_immutable()') is null then null
       else has_function_privilege('anon', 'public._trg_task_log_immutable()', 'execute') end as trg_task_log_immutable_anon,
  case when to_regprocedure('public._trg_task_log_changes()') is null then null
       else has_function_privilege('anon', 'public._trg_task_log_changes()', 'execute') end as trg_task_log_changes_anon;
