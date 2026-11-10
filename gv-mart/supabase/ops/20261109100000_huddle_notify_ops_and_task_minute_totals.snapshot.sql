-- READ-ONLY snapshot for migration 20261109100000_huddle_notify_ops_and_task_minute_totals.sql (Step 3).
-- Run by hand, before and after the GO APPLY script. Nothing here writes anything. Safe to run at any
-- time, including before 11:00 IST. Every reference to an object this migration creates, or that a prior
-- package creates, is guarded with to_regclass/to_regprocedure (never a bare literal ::regclass/
-- ::regprocedure cast) so this runs cleanly regardless of what has been applied so far.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Prerequisites: P2 and P3 must already be registered, and public.task_logs (P3's own table) must exist.
select
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261102100000') as p2_registered,
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261103100000') as p3_registered,
  to_regclass('public.task_logs') is not null as task_logs_exists;

-- Fingerprint of the rows this migration's correctness depends on (REAL orgs only, same formula as the
-- apply script's pre/post check). Run before and after; must be byte-identical in both runs since this
-- migration touches no table rows.
--
-- task_logs_count is deliberately NOT included here even guarded: unlike a literal ::regclass/
-- ::regprocedure cast (lazily resolved only via to_regclass/to_regprocedure), a table name inside a FROM
-- clause is resolved at PARSE time for the whole statement regardless of which CASE branch would run --
-- there is no lazy form of "SELECT ... FROM a_table_that_might_not_exist_yet" in plain SQL, so a CASE
-- guard does not help here the way it does for a cast. (This was found the hard way: an earlier draft of
-- this exact query referenced public.task_logs directly inside a CASE branch and errored 42P01 when P3
-- had not yet been applied.) task_logs' own row count/fingerprint is already covered by P3's own
-- companion snapshot (20261103100000_task_logs_and_visibility.snapshot.sql); this query only needs
-- notifications and meeting_issues, neither of which depends on P3.
select
  md5(coalesce((select string_agg(n.id::text || ':' || n.type || ':' || coalesce(n.user_id::text,'-'), ',' order by n.id)
             from public.notifications n where n.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%'), '')) as huddle_notifications_fingerprint,
  md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || coalesce(i.solution,'-'), ',' order by i.id)
             from public.meeting_issues i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as meeting_issues_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261109100000'
) as already_registered;

-- Current live definition of public._trg_meeting_issue_notify() -- the ONE function this migration
-- redefines. Expect the pre-Step-3 (P2) body (role::text = 'master' only) before the apply, and the
-- widened body (role in ('master','operation_admin')) after. Guarded: NULL only if the function were ever
-- absent (it should not be -- created by P2, 2026-11-02).
select case when to_regprocedure('public._trg_meeting_issue_notify()') is null then null
            else pg_get_functiondef(to_regprocedure('public._trg_meeting_issue_notify()')) end as trg_meeting_issue_notify_def;

-- Whether each of the 2 new views already exists (expect false before, true after), and their
-- security_invoker setting once they exist.
select
  to_regclass('public.task_minute_totals') is not null as task_minute_totals_exists,
  to_regclass('public.person_minute_totals') is not null as person_minute_totals_exists,
  case when to_regclass('public.task_minute_totals') is null then null
       else (select coalesce(reloptions, array[]::text[]) @> array['security_invoker=true'] from pg_class where oid = to_regclass('public.task_minute_totals')) end as task_minute_totals_security_invoker,
  case when to_regclass('public.person_minute_totals') is null then null
       else (select coalesce(reloptions, array[]::text[]) @> array['security_invoker=true'] from pg_class where oid = to_regclass('public.person_minute_totals')) end as person_minute_totals_security_invoker;

-- Privilege state, guarded against each object being absent. anon should be false/NULL everywhere both
-- before and after; authenticated should flip to true for the two views only after the apply.
select
  case when to_regprocedure('public._trg_meeting_issue_notify()') is null then null
       else has_function_privilege('anon', 'public._trg_meeting_issue_notify()', 'execute') end as trg_meeting_issue_notify_anon,
  case when to_regclass('public.task_minute_totals') is null then null
       else has_table_privilege('anon', 'public.task_minute_totals', 'SELECT') end as task_minute_totals_anon,
  case when to_regclass('public.task_minute_totals') is null then null
       else has_table_privilege('authenticated', 'public.task_minute_totals', 'SELECT') end as task_minute_totals_authenticated,
  case when to_regclass('public.person_minute_totals') is null then null
       else has_table_privilege('anon', 'public.person_minute_totals', 'SELECT') end as person_minute_totals_anon,
  case when to_regclass('public.person_minute_totals') is null then null
       else has_table_privilege('authenticated', 'public.person_minute_totals', 'SELECT') end as person_minute_totals_authenticated;
