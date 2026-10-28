-- READ-ONLY snapshot for migration 20261101110000_current_technician_id_active.sql (P1b). Run by hand,
-- before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Guarded with to_regprocedure/to_regclass so it never errors on an object that may not
-- exist yet (current_technician_id() itself always exists -- this migration only redefines it -- but the
-- guard pattern is kept for consistency with the other packages' snapshots).

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
  (select count(*) from public.technicians t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as technicians_count,
  md5(coalesce((select string_agg(t.id::text || ':' || t.is_active::text, ',' order by t.id)
             from public.technicians t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as technicians_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261101110000'
) as already_registered;

-- Current live definition of public.current_technician_id() -- expect the pre-P1b body (no is_active
-- check) before the apply, and the new body (with `and t.is_active`) after. Guarded: NULL if the function
-- were ever absent (it should not be).
select case when to_regprocedure('public.current_technician_id()') is null then null
            else pg_get_functiondef(to_regprocedure('public.current_technician_id()')) end as current_technician_id_def;

-- Structural facts and privilege state, guarded against the function being absent.
select
  case when to_regprocedure('public.current_technician_id()') is null then null
       else (select provolatile = 's' and prosecdef and coalesce(proconfig::text like '%search_path=%', false)
             from pg_proc where pronamespace = 'public'::regnamespace and proname = 'current_technician_id') end as is_stable_security_definer_fixed_search_path,
  case when to_regprocedure('public.current_technician_id()') is null then null
       else has_function_privilege('authenticated', 'public.current_technician_id()', 'execute') end as executable_by_authenticated,
  case when to_regprocedure('public.current_technician_id()') is null then null
       else has_function_privilege('anon', 'public.current_technician_id()', 'execute') end as executable_by_anon;
