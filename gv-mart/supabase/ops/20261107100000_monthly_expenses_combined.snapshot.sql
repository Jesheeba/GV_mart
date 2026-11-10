-- READ-ONLY snapshot for the combined 6-migration GO APPLY script (20261107100000 through
-- 20261107100500, Monthly Expenses). Run by hand, before and after the GO APPLY script. Nothing here
-- writes anything. Safe to run at any time, including before 11:00 IST. Every reference to an object any
-- of these 6 migrations creates is guarded with to_regprocedure/to_regclass/information_schema so this
-- runs cleanly before the apply. (Units 1-2, technician_vehicles/technician_km_log, already have their
-- own standalone snapshots; this one covers the whole package plus Units 3-6's new objects and the two
-- redefined functions.)

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Fingerprint of the rows this package's redefined functions depend on (REAL orgs only, same formula the
-- rehearsal and apply script use). Run before and after; must be byte-identical in both runs since none
-- of these 6 migrations backfills or touches an existing row.
select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s | settings=%s',
    (select count(*) from salaries s2 join organizations o on o.id = s2.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select coalesce(sum(net), 0) from salaries s2 join organizations o on o.id = s2.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select count(*) from incentives_earned i join organizations o on o.id = i.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select coalesce(sum(amount), 0) from incentives_earned i join organizations o on o.id = i.org_id where o.name not like '\_\_TEST%' escape '\'),
    (select md5((to_jsonb(s) - 'own_bike_allowance_base')::text) from settings s join organizations o on o.id = s.org_id where o.name not like '\_\_TEST%' escape '\')
  ) as fingerprint;

-- Whether any of the 6 versions are already registered.
select version, (version is not null) as registered
from (values ('20261107100000'), ('20261107100100'), ('20261107100200'), ('20261107100300'), ('20261107100400'), ('20261107100500')) as v(version)
where exists (select 1 from supabase_migrations.schema_migrations m where m.version = v.version);

-- Current live definitions of the two redefined functions -- expect their pre-package bodies (no Unit 5/6
-- blocks) before the apply, and the widened bodies after.
select pg_get_functiondef('public.compute_incentives(uuid,date)'::regprocedure) as compute_incentives_def;
select pg_get_functiondef('public.compute_salary(uuid,uuid,date)'::regprocedure) as compute_salary_def;

-- Units 3-4: whether each new table/function already exists (expect false/NULL before, true/not-null
-- after).
select
  to_regclass('public.expense_claims') is not null as expense_claims_table_exists,
  to_regprocedure('public.submit_expense_claim(uuid,text,numeric,text,date)') is not null as submit_expense_claim_exists,
  to_regprocedure('public.verify_expense_claim(uuid,numeric,text)') is not null as verify_expense_claim_exists,
  to_regprocedure('public.technician_expense_claims_total(uuid,uuid,date,text)') is not null as technician_expense_claims_total_exists,
  to_regclass('public.person_allowances') is not null as person_allowances_table_exists,
  to_regclass('public.monthly_adjustments') is not null as monthly_adjustments_table_exists,
  to_regprocedure('public.person_allowance_on(uuid,uuid,date)') is not null as person_allowance_on_exists,
  to_regprocedure('public.monthly_adjustment_top_up(uuid,uuid,date,text)') is not null as monthly_adjustment_top_up_exists,
  to_regprocedure('public.monthly_adjustment_excluded(uuid,uuid,date,text)') is not null as monthly_adjustment_excluded_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'own_bike_allowance_base') as settings_own_bike_allowance_base_exists;

-- Units 5-6: whether the new columns on incentives_earned/salaries already exist.
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'incentives_earned' and column_name = 'is_bike_allowance') as incentives_earned_is_bike_allowance_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'salaries' and column_name = 'recharge_amount') as salaries_recharge_amount_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'salaries' and column_name = 'petrol_amount') as salaries_petrol_amount_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'salaries' and column_name = 'maintenance_amount') as salaries_maintenance_amount_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'salaries' and column_name = 'bike_allowance_amount') as salaries_bike_allowance_amount_exists;

-- Privilege state, guarded against each function being absent. anon should be false/NULL both before and
-- after for every one of these; the strictly-internal functions are never granted to authenticated either.
select
  case when to_regprocedure('public.compute_incentives(uuid,date)') is null then null
       else has_function_privilege('anon', 'public.compute_incentives(uuid, date)', 'execute') end as compute_incentives_anon,
  case when to_regprocedure('public.compute_salary(uuid,uuid,date)') is null then null
       else has_function_privilege('anon', 'public.compute_salary(uuid, uuid, date)', 'execute') end as compute_salary_anon,
  case when to_regprocedure('public.submit_expense_claim(uuid,text,numeric,text,date)') is null then null
       else has_function_privilege('anon', 'public.submit_expense_claim(uuid, text, numeric, text, date)', 'execute') end as submit_expense_claim_anon,
  case when to_regprocedure('public.verify_expense_claim(uuid,numeric,text)') is null then null
       else has_function_privilege('anon', 'public.verify_expense_claim(uuid, numeric, text)', 'execute') end as verify_expense_claim_anon;
