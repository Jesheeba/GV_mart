-- READ-ONLY snapshot for migration 20261115110000_expense_categories_schema.sql. Run by hand, before and
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
  select 1 from supabase_migrations.schema_migrations where version = '20261115110000'
) as already_registered;

select
  to_regclass('public.expense_categories') is not null as table_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') as category_id_column_exists;

select
  case when to_regclass('public.expense_categories') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.expense_categories')) end as rls_enabled,
  case when to_regclass('public.expense_categories') is null then null
       else has_table_privilege('anon', 'public.expense_categories', 'SELECT') end as select_by_anon;

-- The live expense_category enum values (must be unchanged by this migration -- additive only).
select array_agg(enumlabel order by enumsortorder) as expense_category_enum_values
from pg_enum where enumtypid = 'public.expense_category'::regtype;

-- NOT part of the before/after pair above (the planner must resolve public.expense_categories to
-- plan this query at all, so it would fail the whole batch before the table exists). Run this one
-- query BY ITSELF, AFTER the apply, to see the real organisation's seeded system-category count
-- (expect exactly 12):
--   select count(*) from public.expense_categories ec
--   where ec.org_id = (select o.id from public.organizations o where o.name not like '__TEST%' escape '' order by o.created_at asc limit 1)
--     and ec.is_system;
