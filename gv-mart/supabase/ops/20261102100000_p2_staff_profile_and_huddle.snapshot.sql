-- READ-ONLY snapshot for migration 20261102100000_p2_staff_profile_and_huddle.sql (P2). Run by hand,
-- before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with to_regprocedure /
-- to_regclass / information_schema so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Fingerprint of the rows this migration's correctness depends on (REAL orgs only, same formula as the
-- apply script's pre/post check -- deliberately excludes every column this migration adds, in particular
-- profiles.task_color, which this migration legitimately backfills). Run before and after; must be
-- byte-identical in both runs.
select
  md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.role::text || ':' || p.is_active::text || ':' || p.full_name || ':' || coalesce(p.phone, ''), ',' order by p.id)
             from public.profiles p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as profiles_fingerprint,
  md5(coalesce((select string_agg(i.id::text || ':' || i.status || ':' || i.description || ':' || coalesce(i.raised_by::text, '-') || ':' || coalesce(i.solution, ''), ',' order by i.id)
             from public.meeting_issues i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as meeting_issues_fingerprint,
  (select count(*) from public.notifications n where n.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%') and n.type like 'huddle\_%') as huddle_notifications_count,
  (select count(*) from public.meeting_logs m where m.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as meeting_logs_count;

-- Informational only: how many existing non-customer profiles currently have no task_color (these are the
-- rows the backfill will set). Expect this to go to 0 after the apply.
select count(*) as profiles_pending_task_color_backfill
from public.profiles p
where p.role::text <> 'customer'
  and (to_jsonb(p) ->> 'task_color') is null;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261102100000'
) as already_registered;

-- Current live definition of public.wa_send_huddle_reminder(uuid) -- the ONE function this migration
-- redefines. Expect the pre-P2 body (no recorded_by/general_notes test) before the apply, and the new body
-- after. Guarded: NULL only if the function were ever absent (it should not be -- created 2026-09-29).
select case when to_regprocedure('public.wa_send_huddle_reminder(uuid)') is null then null
            else pg_get_functiondef(to_regprocedure('public.wa_send_huddle_reminder(uuid)')) end as wa_send_huddle_reminder_def;

-- Whether each of the 10 brand-new objects already exists (expect false/NULL before the apply, true/not-
-- null after).
select
  to_regprocedure('public.guard_profile_staff_fields()') is not null as guard_profile_staff_fields_exists,
  to_regprocedure('public._trg_profile_password_marker()') is not null as trg_profile_password_marker_exists,
  to_regprocedure('public.arm_forced_password_change(uuid)') is not null as arm_forced_password_change_exists,
  to_regprocedure('public.complete_forced_password_change()') is not null as complete_forced_password_change_exists,
  to_regprocedure('public._hsl_hex(numeric, numeric, numeric)') is not null as hsl_hex_exists,
  to_regprocedure('public._trg_profile_assign_color()') is not null as trg_profile_assign_color_exists,
  to_regprocedure('public._trg_meeting_issue_stamp()') is not null as trg_meeting_issue_stamp_exists,
  to_regprocedure('public._trg_meeting_issue_notify()') is not null as trg_meeting_issue_notify_exists,
  to_regprocedure('public.raise_huddle_issue(text)') is not null as raise_huddle_issue_exists,
  to_regprocedure('public.propose_huddle_solution(uuid, text)') is not null as propose_huddle_solution_exists,
  to_regclass('public.profile_password_markers') is not null as profile_password_markers_table_exists,
  to_regclass('public.staff_private') is not null as staff_private_table_exists;

-- Privilege state of every function this migration creates or redefines (guarded; NULL before each
-- individually exists). anon should be false/NULL everywhere both before and after; authenticated should
-- flip to true, after the apply, for complete_forced_password_change/raise_huddle_issue/
-- propose_huddle_solution only.
select
  case when to_regprocedure('public.wa_send_huddle_reminder(uuid)') is null then null
       else has_function_privilege('anon', 'public.wa_send_huddle_reminder(uuid)', 'execute') end as wa_send_huddle_reminder_anon,
  case when to_regprocedure('public.complete_forced_password_change()') is null then null
       else has_function_privilege('anon', 'public.complete_forced_password_change()', 'execute') end as complete_forced_password_change_anon,
  case when to_regprocedure('public.complete_forced_password_change()') is null then null
       else has_function_privilege('authenticated', 'public.complete_forced_password_change()', 'execute') end as complete_forced_password_change_authenticated,
  case when to_regprocedure('public.raise_huddle_issue(text)') is null then null
       else has_function_privilege('anon', 'public.raise_huddle_issue(text)', 'execute') end as raise_huddle_issue_anon,
  case when to_regprocedure('public.raise_huddle_issue(text)') is null then null
       else has_function_privilege('authenticated', 'public.raise_huddle_issue(text)', 'execute') end as raise_huddle_issue_authenticated,
  case when to_regprocedure('public.propose_huddle_solution(uuid, text)') is null then null
       else has_function_privilege('anon', 'public.propose_huddle_solution(uuid, text)', 'execute') end as propose_huddle_solution_anon,
  case when to_regprocedure('public.propose_huddle_solution(uuid, text)') is null then null
       else has_function_privilege('authenticated', 'public.propose_huddle_solution(uuid, text)', 'execute') end as propose_huddle_solution_authenticated;
