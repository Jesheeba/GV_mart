-- READ-ONLY snapshot for migration 20261101100000_task_completion_rule.sql (P1a). Run by hand, before and
-- after the GO APPLY script, to eyeball state independently of the apply script's own checks. Nothing here
-- writes anything. Safe to run at any time, including before 11:00 IST.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Row counts and fingerprint of the two tables this migration's correctness depends on (REAL orgs only,
-- same formula as the apply script's pre/post check). Run before and after; the three values must be
-- byte-identical in both runs since this migration touches no table rows.
select
  (select count(*) from public.tasks t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as tasks_count,
  (select count(*) from public.purchase_orders po where po.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as purchase_orders_count,
  md5(coalesce((select string_agg(t.id::text || ':' || t.status::text || ':' || coalesce(t.assignee_id::text, '-') || ':' || coalesce(t.assigned_by::text, '-'), ',' order by t.id)
             from public.tasks t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as tasks_fingerprint,
  md5(coalesce((select string_agg(po.id::text || ':' || po.status::text, ',' order by po.id)
             from public.purchase_orders po where po.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as purchase_orders_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261101100000'
) as already_registered;

-- Current live definition of public.guard_task_completion() -- expect NULL (does not exist yet) before
-- the apply, and the new function body after.
select pg_get_functiondef(p.oid) as guard_task_completion_def
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guard_task_completion';

-- Current live definition of public._po_task_completed_marks_paid() -- expect the pre-P1a body before
-- the apply (no master-only gate), and the hardened body (with the auth.uid()/is_master() check) after.
select pg_get_functiondef(p.oid) as po_task_completed_marks_paid_def
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = '_po_task_completed_marks_paid';

-- Current live definition of the tasks_update_assign policy -- expect the pre-P1a USING clause (no
-- assignee/assigned_by restriction) before the apply, and the narrowed clause after.
select pol.polname, pg_get_expr(pol.polqual, pol.polrelid) as using_clause,
       pg_get_expr(pol.polwithcheck, pol.polrelid) as with_check_clause
from pg_policy pol
where pol.polrelid = 'public.tasks'::regclass and pol.polname = 'tasks_update_assign';

-- Whether the new trigger exists, fires on the right events, and is not directly callable by a client.
select
  exists (
    select 1 from pg_trigger t
    where t.tgrelid = 'public.tasks'::regclass and t.tgname = 'aa_guard_task_completion' and not t.tgisinternal
      and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4 and (t.tgtype & 16) = 16
  ) as trigger_exists_before_insert_or_update,
  case when to_regprocedure('public.guard_task_completion()') is null then null
       else has_function_privilege('authenticated', 'public.guard_task_completion()', 'execute') end as guard_executable_by_authenticated,
  case when to_regprocedure('public.guard_task_completion()') is null then null
       else has_function_privilege('anon', 'public.guard_task_completion()', 'execute') end as guard_executable_by_anon,
  has_function_privilege('anon', 'public._po_task_completed_marks_paid()', 'execute') as po_marks_paid_executable_by_anon;
