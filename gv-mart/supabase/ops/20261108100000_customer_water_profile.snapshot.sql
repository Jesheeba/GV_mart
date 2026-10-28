-- READ-ONLY snapshot for migration 20261108100000_customer_water_profile.sql. Run by hand, before and
-- after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including before
-- 11:00 IST. Every reference to an object this migration creates is guarded with to_regprocedure/
-- to_regclass/to_regtype so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Row count + content fingerprint of customers (REAL orgs only -- same formula as the apply script's
-- pre/post check). Run before and after; must be byte-identical in both runs since this migration
-- touches no existing row.
select
  count(*) as customers_count,
  md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), '')) as customers_fingerprint
from public.customers
where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261108100000'
) as already_registered;

-- Whether each new object already exists (expect false/NULL before, true/not-null after).
select
  to_regprocedure('public.guard_water_profile_edit_roles()') is not null as guard_water_profile_edit_roles_exists,
  to_regprocedure('public.stamp_customer_health_profile()') is not null as stamp_customer_health_profile_exists,
  to_regprocedure('public.get_customer_health_condition(uuid)') is not null as get_customer_health_condition_exists,
  to_regclass('public.customer_health_profile') is not null as customer_health_profile_table_exists,
  to_regtype('public.household_health_level') is not null as household_health_level_type_exists;

-- Whether the 5 new columns already exist (expect false before, true after).
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'water_source') as customers_water_source_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'water_source_other') as customers_water_source_other_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'water_tds_ppm') as customers_water_tds_ppm_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'water_ph') as customers_water_ph_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'show_health_condition_to_technicians') as settings_show_health_condition_exists;

-- RLS + privilege state of customer_health_profile, guarded against it being absent.
select
  case when to_regclass('public.customer_health_profile') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.customer_health_profile')) end as customer_health_profile_rls_enabled,
  case when to_regclass('public.customer_health_profile') is null then null
       else has_table_privilege('anon', 'public.customer_health_profile', 'SELECT') end as customer_health_profile_select_by_anon,
  case when to_regclass('public.customer_health_profile') is null then null
       else has_table_privilege('authenticated', 'public.customer_health_profile', 'SELECT') end as customer_health_profile_select_by_authenticated,
  case when to_regprocedure('public.get_customer_health_condition(uuid)') is null then null
       else has_function_privilege('anon', 'public.get_customer_health_condition(uuid)', 'execute') end as get_customer_health_condition_anon,
  case when to_regprocedure('public.get_customer_health_condition(uuid)') is null then null
       else has_function_privilege('authenticated', 'public.get_customer_health_condition(uuid)', 'execute') end as get_customer_health_condition_authenticated;
