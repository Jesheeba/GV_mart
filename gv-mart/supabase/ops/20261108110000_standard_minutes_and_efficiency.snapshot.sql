-- READ-ONLY snapshot for migration 20261108110000_standard_minutes_and_efficiency.sql (P5). Run by hand,
-- before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with to_regprocedure
-- so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Fingerprint of the four tables report_ops_resolution/report_kpi_tiles/report_performance_efficiency
-- only ever READ (REAL org only, same formula as the apply script's pre/post check). Run before and
-- after; must be byte-identical in both runs since this migration touches no table rows.
select format('customers=%s ids_md5=%s | service_tickets=%s ids_md5=%s | invoices=%s ids_md5=%s | products=%s ids_md5=%s',
    (select count(*) from public.customers c where c.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select md5(coalesce(string_agg(c.id::text, ',' order by c.id), '')) from public.customers c where c.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select count(*) from public.service_tickets t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select md5(coalesce(string_agg(t.id::text, ',' order by t.id), '')) from public.service_tickets t where t.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select count(*) from public.invoices i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select md5(coalesce(string_agg(i.id::text, ',' order by i.id), '')) from public.invoices i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select count(*) from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')),
    (select md5(coalesce(string_agg(p.id::text, ',' order by p.id), '')) from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%'))
  ) as four_table_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261108110000'
) as already_registered;

-- Current live definitions of the two redefined functions -- expect their pre-P5 bodies (no sla_hours /
-- no settings-driven SLA) before the apply, and the new bodies after.
select pg_get_functiondef('public.report_ops_resolution(date,date)'::regprocedure) as report_ops_resolution_def;
select pg_get_functiondef('public.report_kpi_tiles(date,date)'::regprocedure) as report_kpi_tiles_def;

-- Whether the new RPC already exists (expect false before, true after), and its privilege state guarded
-- against it being absent.
select
  to_regprocedure('public.report_performance_efficiency(date,date)') is not null as report_performance_efficiency_exists,
  case when to_regprocedure('public.report_performance_efficiency(date,date)') is null then null
       else has_function_privilege('anon', 'public.report_performance_efficiency(date, date)', 'execute') end as report_performance_efficiency_anon,
  case when to_regprocedure('public.report_performance_efficiency(date,date)') is null then null
       else has_function_privilege('authenticated', 'public.report_performance_efficiency(date, date)', 'execute') end as report_performance_efficiency_authenticated;

-- Whether the three new columns already exist (expect false before, true after).
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'complaint_types' and column_name = 'standard_minutes') as complaint_types_standard_minutes_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'job_overrun_buffer_minutes') as settings_job_overrun_buffer_minutes_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'ops_resolution_sla_hours') as settings_ops_resolution_sla_hours_exists;
