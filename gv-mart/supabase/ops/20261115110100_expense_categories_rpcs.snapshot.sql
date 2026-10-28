-- READ-ONLY snapshot for migration 20261115110100_expense_categories_rpcs.sql. Run by hand, before and
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
  select 1 from supabase_migrations.schema_migrations where version = '20261115110100'
) as already_registered;

select
  to_regprocedure('public.create_expense_category(text)') is not null as create_exists,
  to_regprocedure('public.rename_expense_category(uuid,text)') is not null as rename_exists,
  to_regprocedure('public.deactivate_expense_category(uuid)') is not null as deactivate_exists,
  to_regprocedure('public.delete_expense_category(uuid)') is not null as delete_exists;
