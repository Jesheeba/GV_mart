-- DRYRUN copy of 20261204170000_address_sub_area_field.apply.sql -- byte-identical
-- except for one added line at the very end: an unconditional RAISE after every check has
-- already passed, forcing the whole statement to roll back. Run this first; only run the real
-- .apply.sql after this comes back DRYRUN_OK, and only after the owner types APPROVED.
--
-- Scope note: this migration is additive-only DDL -- one nullable column, no functions, no
-- grants, no RLS policy changes, no RPC changes (create_customer_with_details is untouched;
-- a brand-new customer's primary address gets sub_area written as a small follow-up update,
-- same pattern as setAddressZone/setAddressStructuredFields). No leak-snapshot/anon-exposure
-- step is needed for the same reason: nothing here changes what any role can execute.
--
-- *** PIN STATUS -- READ BEFORE RUNNING ***
-- v_expected_org_fingerprint below is CARRIED FORWARD from the most recent live-verified
-- capture of this value, in 20261103120000_address_water_household_fields.apply.sql
-- (pin 6f891cf85011f08c2f22fb4a208d21bd, itself re-checked live that day). This file was
-- authored in a clean worktree with no live DB credentials available, so that carry-forward
-- has NOT been re-verified fresh against today's data. The script still recomputes and
-- compares it at run time (step 0 below) -- if the oldest real organisation has changed since
-- 2026-11-03, this will fail safely with APPLY_REFUSED rather than silently proceeding on a
-- stale value. If it refuses on that specific check, re-run the capture query in this same
-- file's header comment below, update v_expected_org_fingerprint here AND in the matching
-- .apply.sql, and re-run.
--
-- To (re-)capture the org fingerprint yourself, run this one-liner against live first:
--   select md5(o.id::text || '|' || o.name) from public.organizations o
--   where o.name not like '\_\_TEST\_%' escape '\' order by o.created_at asc, o.id asc limit 1;
--
-- v_expected_migration_hash was computed locally from the committed migration file itself
-- (supabase/migrations/20261204170000_address_sub_area_field.sql, CR-stripped sha256) --
-- this one needed no live access and is accurate as of this commit.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint (see PIN STATUS above).
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. ALREADY-REGISTERED CHECK -- refuses if 20261204170000 is already registered.
--   3. NEW-COLUMN PRE-CHECK -- sub_area may not already exist on public.addresses.
--   4. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of
--                           public.addresses, over REAL organisations only. A purely additive
--                           nullable column never touches existing row content, so this must
--                           be identical after.
--   5. PIN              -- CR-tolerant sha256 of the embedded migration text must equal
--                           1d1cdf72e10adfb0d1051f7930c89f2fab4e38c2ff755dfe897d74dcd986a53a,
--                           independently computed from the committed file
--                           (supabase/migrations/20261204170000_address_sub_area_field.sql)
--                           before this script was written.
--   6. RUN              -- EXECUTE the migration, verbatim (CR-tolerant).
--   7. REGISTER         -- INSERT the version row into supabase_migrations.schema_migrations,
--                           in the same transaction as the migration itself.
--   8. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      8a. sub_area now exists on public.addresses, data_type text, is_nullable = 'YES';
--      8b. the real addresses fingerprint is unchanged from step 4.
--   9. On success, INSERT the one status row into pg_temp.sub_area_apply_status.
--
-- Rollback: supabase/rollbacks/20261204170000_address_sub_area_field.rollback.sql
-- (one `drop column if exists`) -- already committed, reviewed alongside this script.

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
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %) -- re-capture and update the pin, see PIN STATUS in this file''s header', v_expected_org_fingerprint, v_org_fingerprint;
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

  -- 9. Every check above passed.
  insert into pg_temp.sub_area_apply_status (
    version_registered, column_exists, column_type_correct, addresses_fingerprint_unchanged, applied_at
  )
  values (
    '20261204170000', v_column_exists, v_type_correct,
    (v_addr_count_after = v_addr_count_before and v_addr_md5_after = v_addr_md5_before),
    now()
  );

  -- DRYRUN ONLY: every check above passed -- force a rollback so nothing from this run
  -- persists, including the schema_migrations row and the new column.
  -- This is the one and only difference from the real apply script.
  raise exception 'DRYRUN_OK: all apply-script checks passed; nothing was committed (forced rollback)';
end
$apply$;

select * from pg_temp.sub_area_apply_status;
