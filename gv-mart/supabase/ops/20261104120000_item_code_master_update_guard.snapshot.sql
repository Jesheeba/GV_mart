-- READ-ONLY snapshot for migration 20261104120000_item_code_master_update_guard.sql (P4 part 3). Run by
-- hand, before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time,
-- including before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Prerequisite: P4 part 1 must already be registered, and products.item_code must exist.
select
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261104100000') as p4_part1_registered,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'item_code') as products_item_code_exists;

-- Row count and fingerprint of products (REAL orgs only -- same formula as the apply script's pre/post
-- check). Run before and after; must be byte-identical in both runs since this migration touches no
-- table rows.
select
  (select count(*) from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as products_count,
  md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
             from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as products_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261104120000'
) as already_registered;

-- Whether the new function and its trigger already exist (expect false before, true after), and
-- privilege state guarded against the function being absent.
select
  to_regprocedure('public.guard_item_code_update()') is not null as guard_function_exists,
  exists (select 1 from pg_trigger t where t.tgrelid = 'public.products'::regclass and t.tgname = 'guard_item_code_update' and not t.tgisinternal) as guard_trigger_exists,
  case when to_regprocedure('public.guard_item_code_update()') is null then null
       else has_function_privilege('anon', 'public.guard_item_code_update()', 'execute') end as guard_function_anon;
