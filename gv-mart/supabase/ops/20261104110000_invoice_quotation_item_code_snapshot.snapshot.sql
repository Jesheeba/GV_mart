-- READ-ONLY snapshot for migration 20261104110000_invoice_quotation_item_code_snapshot.sql (P4 part 2).
-- Run by hand, before and after the GO APPLY script. Nothing here writes anything. Safe to run at any
-- time, including before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/information_schema so this runs cleanly before the apply.

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

-- Row count and fingerprint of invoice_items/quotation_items (REAL orgs only, excluding item_code -- same
-- formula as the apply script's pre/post check). Run before and after; must be byte-identical in both runs.
select
  (select count(*) from public.invoice_items i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as invoice_items_count,
  (select count(*) from public.quotation_items q where q.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')) as quotation_items_count,
  md5(coalesce((select string_agg(i.id::text || ':' || i.org_id::text || ':' || i.invoice_id::text || ':' || i.item_type::text || ':' || i.item_id::text || ':' || i.qty::text || ':' || i.price::text, ',' order by i.id)
             from public.invoice_items i where i.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as invoice_items_fingerprint,
  md5(coalesce((select string_agg(q.id::text || ':' || q.org_id::text || ':' || q.quotation_id::text || ':' || q.item_type::text || ':' || q.item_id::text || ':' || q.qty::text || ':' || q.price::text, ',' order by q.id)
             from public.quotation_items q where q.org_id in (select id from public.organizations o where o.name not like '\_\_TEST\_%')), '')) as quotation_items_fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261104110000'
) as already_registered;

-- Whether each new object already exists (expect false/NULL before, true after).
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoice_items' and column_name = 'item_code') as invoice_items_item_code_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'quotation_items' and column_name = 'item_code') as quotation_items_item_code_exists,
  to_regprocedure('public._stamp_item_code()') is not null as stamp_item_code_function_exists;

-- Trigger existence + privilege state, guarded against the function being absent.
select
  exists (select 1 from pg_trigger t where t.tgrelid = 'public.invoice_items'::regclass and t.tgname = 'aa_stamp_item_code' and not t.tgisinternal) as invoice_items_trigger_exists,
  exists (select 1 from pg_trigger t where t.tgrelid = 'public.quotation_items'::regclass and t.tgname = 'aa_stamp_item_code' and not t.tgisinternal) as quotation_items_trigger_exists,
  case when to_regprocedure('public._stamp_item_code()') is null then null
       else has_function_privilege('anon', 'public._stamp_item_code()', 'execute') end as stamp_item_code_anon;
