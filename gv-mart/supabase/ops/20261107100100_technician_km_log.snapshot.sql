-- READ-ONLY snapshot for migration 20261107100100_technician_km_log.sql (Monthly Expenses Unit 2). Run
-- by hand, before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time,
-- including before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/to_regclass so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Prerequisite: 20261107100000 must already be registered, and technician_vehicles must exist.
select
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261107100000') as prereq_registered,
  to_regclass('public.technician_vehicles') is not null as technician_vehicles_exists;

-- Fingerprint of the rows this expenses package depends on (REAL orgs only).
select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
    (select count(*) from salaries s2 join organizations o on o.id = s2.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select coalesce(sum(net), 0) from salaries s2 join organizations o on o.id = s2.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select count(*) from incentives_earned i join organizations o on o.id = i.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select coalesce(sum(amount), 0) from incentives_earned i join organizations o on o.id = i.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s join organizations o on o.id = s.org_id where o.name not like '\_\_TEST%' escape '\')
  ) as fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261107100100'
) as already_registered;

-- Whether each new object already exists (expect false/NULL before, true/not-null after).
select
  to_regclass('public.technician_km_log') is not null as technician_km_log_table_exists,
  to_regprocedure('public.technician_km_log_sum(uuid,uuid,date)') is not null as technician_km_log_sum_exists,
  to_regprocedure('public.technician_petrol_reference_amount(uuid,uuid,date)') is not null as technician_petrol_reference_amount_exists,
  to_regprocedure('public.technician_approx_distance_km(uuid,uuid,date)') is not null as technician_approx_distance_km_exists;

-- Privilege state, guarded against each function being absent.
select
  case when to_regprocedure('public.technician_km_log_sum(uuid,uuid,date)') is null then null
       else has_function_privilege('anon', 'public.technician_km_log_sum(uuid, uuid, date)', 'execute') end as technician_km_log_sum_anon,
  case when to_regprocedure('public.technician_petrol_reference_amount(uuid,uuid,date)') is null then null
       else has_function_privilege('anon', 'public.technician_petrol_reference_amount(uuid, uuid, date)', 'execute') end as technician_petrol_reference_amount_anon,
  case when to_regprocedure('public.technician_approx_distance_km(uuid,uuid,date)') is null then null
       else has_function_privilege('anon', 'public.technician_approx_distance_km(uuid, uuid, date)', 'execute') end as technician_approx_distance_km_anon;
