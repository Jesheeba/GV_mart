-- GO APPLY script for 20261204170000_address_sub_area_field.sql (one new nullable column
-- on public.addresses: sub_area text -- the "Sub Area" field from clean_address_form.pdf,
-- the one structured address field the clean-address-form redesign needed that had no
-- column anywhere in this schema).
--
-- DRYRUN must run clean against live first and is the authority for "this is safe":
-- 20261204170000_address_sub_area_field.apply.dryrun.sql, byte-identical to this file
-- except for its one extra forced-rollback RAISE at the end. Expected result: P0001
-- "DRYRUN_OK: all apply-script checks passed; nothing was committed (forced rollback)",
-- confirming every check below (org fingerprint, already-registered, new-column pre-check,
-- migration-text pin, post-apply column/type check, before/after addresses fingerprint)
-- already passed once, live, with nothing persisted. This file differs from that dryrun by
-- exactly one thing: the final forced-rollback RAISE is removed, so a normal run commits.
--
-- NOT YET APPLIED. NOT YET DRYRUN (built in a clean worktree with no live DB credentials --
-- see the dryrun file's "PIN STATUS" header for what still needs a live re-check before
-- either script is run). Waiting on the owner's typed APPROVED, and on that dryrun actually
-- being run and coming back DRYRUN_OK first.
--
-- Scope note: this migration is additive-only DDL -- one nullable column, no functions, no
-- grants, no RLS policy changes, no RPC changes (create_customer_with_details is untouched;
-- a brand-new customer's primary address gets sub_area written as a small follow-up update,
-- same pattern as setAddressZone/setAddressStructuredFields). No leak-snapshot/anon-exposure
-- step is needed for the same reason the Nov 3 water/household migration didn't need one:
-- nothing here changes what any role can execute.
--
-- Frontend files that already depend on this migration being live (grep across src/,
-- 2026-11-03 clean-address-form stream): src/lib/address.ts (composeFullAddress,
-- splitAddressForForm), src/lib/address.test.ts, src/app/admin/customers/CustomerFormPage.tsx,
-- src/services/customers.ts (setAddressStructuredFields, upsertPrimaryAddress),
-- src/lib/validation/customer.ts, src/lib/i18n/en.json, ta.json, src/types/database.ts
-- (hand-patched ahead of the live schema, same convention as every prior migration here --
-- today's db does not yet have this column, so any save that reaches
-- setAddressStructuredFields / upsertPrimaryAddress with a sub_area value degrades silently
-- (Supabase rejects the unknown column) until this migration is applied). The Sub Area
-- form field itself still works today -- it just can't round-trip back out of a saved row,
-- and only ever flows into the composed full_address text, until this ships.
--
-- Order of operations inside the DO block: see the dryrun file's header -- identical,
-- steps 0-9.
--
-- Rollback: supabase/rollbacks/20261204170000_address_sub_area_field.rollback.sql
-- (one `drop column if exists`) -- already committed, reviewed alongside this script.
-- Exercised (apply -> verify -> rollback -> verify zero residue, all inside one forced-
-- rollback probe): 20261204170000_address_sub_area_field.rollback_exercise.apply.dryrun.sql.
-- Post-apply verification (read-only, run once after the real apply commits):
-- 20261204170000_address_sub_area_field.post_apply_verify.sql.

drop table if exists pg_temp.sub_area_apply_status;
create temp table sub_area_apply_status (
  version_registered         text,
  column_exists               boolean,
  column_type_correct        boolean,
  addresses_fingerprint_unchanged boolean,
  applied_at                  timestamptz
);

do $apply$
declare
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
  v_expected_migration_hash text := '1d1cdf72e10adfb0d1051f7930c89f2fab4e38c2ff755dfe897d74dcd986a53a';
  v_actual_hash text;
  v_already_registered boolean;
  v_pre_existing_count int;
  v_column_exists boolean := false;
  v_type_correct boolean := false;
  v_addr_count_before bigint; v_addr_md5_before text;
  v_addr_count_after bigint; v_addr_md5_after text;
  v_migration_text text;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST\_%' escape '\'
  order by o.created_at asc, o.id asc
  limit 1;
  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %) -- re-capture and update the pin, see PIN STATUS in the .apply.dryrun.sql header', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. ALREADY-REGISTERED CHECK
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261204170000') into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: 20261204170000 is already registered in supabase_migrations.schema_migrations -- stop, nothing applied';
  end if;

  -- 3. NEW-COLUMN PRE-CHECK
  select count(*) into v_pre_existing_count
  from information_schema.columns
  where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area';
  if v_pre_existing_count > 0 then
    raise exception 'APPLY_REFUSED: sub_area already exists on public.addresses before this migration ran';
  end if;

  -- 4. REAL-TABLE FINGERPRINT (BEFORE)
  select count(*), md5(coalesce(string_agg(a.id::text || a.updated_at::text, '' order by a.id), ''))
    into v_addr_count_before, v_addr_md5_before
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  -- 5. PIN
  v_migration_text := $migration$-- Clean-address-form redesign (2026-11-03 stream), Step 1: adds the one
-- structured address field that had no column anywhere in this schema --
-- `sub_area` ("Sub Area" on clean_address_form.pdf, between Street/Cross
-- and Main Area). Every other field the redesign needed (door_no, plot_no,
-- building_name, street_cross, landmark, area, zone) already existed --
-- see 20260701090200_customers.sql, 20260915130000_address_building_fields.sql,
-- 20260702200000_technicians_admin_schema.sql. Mirrors
-- 20261103120000_address_water_household_fields.sql in every way: nullable,
-- additive, no default, no backfill, no RPC change (create_customer_with_details
-- is left untouched; a brand-new customer's primary address gets sub_area
-- written as a small follow-up update, same pattern as setAddressZone/
-- setAddressStructuredFields), no RLS change needed (addresses_write_sales/
-- addresses_write_own already govern the whole row, not per-column).
alter table public.addresses add column if not exists sub_area text;

comment on column public.addresses.sub_area is
  'Added 2026-12-04 — "Sub Area" field from clean_address_form.pdf, captured on the admin Customer form''s address step alongside door_no/plot_no/building_name/street_cross/landmark/area. Feeds into the composed full_address text (see src/lib/address.ts composeFullAddress) the same way those columns do.';
$migration$;

  v_actual_hash := encode(sha256(convert_to(replace(v_migration_text, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_hash;
  end if;

  -- 6. RUN
  execute replace(v_migration_text, E'\r', '');

  -- 7. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261204170000', 'address_sub_area_field', array[replace(v_migration_text, E'\r', '')]);

  -- 8a. column exists with the expected type.
  select
    count(*) = 1,
    bool_and(data_type = 'text' and is_nullable = 'YES')
  into v_column_exists, v_type_correct
  from information_schema.columns
  where table_schema = 'public' and table_name = 'addresses' and column_name = 'sub_area';

  if not v_column_exists then
    raise exception 'APPLY_REFUSED: post-apply check failed -- sub_area does not exist on public.addresses after the migration ran';
  end if;
  if not v_type_correct then
    raise exception 'APPLY_REFUSED: post-apply check failed -- sub_area has an unexpected data_type or is not nullable';
  end if;

  -- 8b. real addresses fingerprint unchanged (this migration writes no row data).
  select count(*), md5(coalesce(string_agg(a.id::text || a.updated_at::text, '' order by a.id), ''))
    into v_addr_count_after, v_addr_md5_after
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  if v_addr_count_after is distinct from v_addr_count_before or v_addr_md5_after is distinct from v_addr_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real addresses fingerprint changed (count before % after %, md5 before % after %)', v_addr_count_before, v_addr_count_after, v_addr_md5_before, v_addr_md5_after;
  end if;

  -- 9. Every step above passed -- this run actually commits (no forced rollback, unlike the dryrun).
  insert into pg_temp.sub_area_apply_status (
    version_registered, column_exists, column_type_correct, addresses_fingerprint_unchanged, applied_at
  )
  values (
    '20261204170000', v_column_exists, v_type_correct,
    (v_addr_count_after = v_addr_count_before and v_addr_md5_after = v_addr_md5_before),
    now()
  );
end
$apply$;

select * from pg_temp.sub_area_apply_status;
