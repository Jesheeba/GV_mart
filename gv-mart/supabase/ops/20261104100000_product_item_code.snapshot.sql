-- READ-ONLY snapshot for migration 20261104100000_product_item_code.sql (P4 part 1). Run by hand, before
-- and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including before
-- 11:00 IST.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Row count and fingerprint of products (REAL orgs only, excluding item_code -- same formula as the apply
-- script's pre/post check). Run before and after; must be byte-identical in both runs.
select
  (select count(*) from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as products_count,
  md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
             from public.products p where p.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as products_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261104100000'
) as already_registered;

-- Whether the column and index already exist (expect false before, true after).
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products' and column_name = 'item_code'
  ) as item_code_column_exists,
  to_regclass('public.products_item_code_unique_idx') is not null as unique_index_exists;
