-- READ-ONLY live-pin capture for 20261204170000_address_sub_area_field.apply.dryrun.sql /
-- .apply.sql. Run this FIRST, against the real database, before either of those scripts.
-- Makes no write of any kind -- no INSERT/UPDATE/DELETE, no DDL, no temp table, nothing
-- persisted, nothing that needs a rollback. Scoped only to public.addresses and
-- public.organizations (the two tables the apply/dryrun scripts' own checks touch) --
-- audit_log is never queried, matching this stream's standing check-scope rule.
--
-- Output: one row with everything the apply/dryrun scripts' hardcoded pins need. Compare
-- org_fingerprint below to the value currently hardcoded in both
-- 20261204170000_address_sub_area_field.apply.sql and .apply.dryrun.sql
-- (v_expected_org_fingerprint := '6f891cf85011f08c2f22fb4a208d21bd', carried forward from the
-- 2026-11-03 water/household migration's own live capture and NOT independently re-verified
-- by this agent, which has no live DB credentials). If they match, the scripts' org check
-- will pass as-is. If they don't, update v_expected_org_fingerprint in BOTH files to the
-- fresh value this query returns before running either one.
--
-- addresses_count / addresses_md5 are given for your own reference only -- the apply/dryrun
-- scripts compute their own before/after fingerprint internally in the same transaction, so
-- there is no separate pin to copy for those; this is just so you can see today's real
-- numbers before running them.
select
  (
    select md5(o.id::text || '|' || o.name)
    from public.organizations o
    where o.name not like '\_\_TEST\_%' escape '\'
    order by o.created_at asc, o.id asc
    limit 1
  ) as org_fingerprint,
  (
    select count(*)
    from public.addresses a
    where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\')
  ) as addresses_count_real_orgs,
  (
    select md5(coalesce(string_agg(a.id::text || a.updated_at::text, '' order by a.id), ''))
    from public.addresses a
    where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\')
  ) as addresses_md5_real_orgs,
  (
    select count(*)
    from information_schema.columns
    where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area'
  ) as sub_area_column_already_exists_count,
  (
    select exists(select 1 from supabase_migrations.schema_migrations where version = '20261204170000')
  ) as migration_already_registered,
  now() as captured_at;
