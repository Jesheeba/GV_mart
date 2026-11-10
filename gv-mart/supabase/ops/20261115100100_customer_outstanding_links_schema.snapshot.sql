-- READ-ONLY snapshot for migration 20261115100100_customer_outstanding_links_schema.sql. Run by hand, before and
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
  select 1 from supabase_migrations.schema_migrations where version = '20261115100100'
) as already_registered;

select to_regclass('public.customer_outstanding_links') is not null as table_exists;

select
  case when to_regclass('public.customer_outstanding_links') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.customer_outstanding_links')) end as rls_enabled,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else has_table_privilege('anon', 'public.customer_outstanding_links', 'SELECT') end as select_by_anon,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else has_table_privilege('authenticated', 'public.customer_outstanding_links', 'SELECT') end as select_by_authenticated,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_outstanding_links' and policyname = 'customer_outstanding_links_select_master') end as select_policy_exists;
