-- GO APPLY script for 20261103120000_address_water_household_fields.sql (4 new nullable
-- columns on public.addresses: water_source text, water_tds integer, water_ph numeric,
-- health_condition text -- the admin Customer form's new "Water & household" review step).
--
-- DRYRUN already ran clean against live and is the authority for "this is safe":
-- 20261103120000_address_water_household_fields.apply.dryrun.sql, byte-identical to this
-- file except for its one extra forced-rollback RAISE at the end. Result: P0001
-- "DRYRUN_OK: all apply-script checks passed; nothing was committed (forced rollback)",
-- confirming every check below (org fingerprint, already-registered, new-column pre-check,
-- migration-text pin, post-apply column/type check, before/after addresses fingerprint) already
-- passed once, live, with nothing persisted. This file differs from that dryrun by exactly one
-- thing: the final forced-rollback RAISE is removed, so a normal run commits.
--
-- NOT YET APPLIED. Waiting on the owner's typed APPROVED.
--
-- Scope note: this migration is additive-only DDL -- no functions, no grants, no RLS policy
-- changes, no RPC changes (create_customer_with_details is untouched; a brand-new customer's
-- primary address gets these written as a small follow-up update, same pattern as
-- setAddressZone/setAddressWaterHousehold). No leak-snapshot step is needed for the same
-- reason the duplicate-contact-warning precedent needed one and this doesn't: nothing here
-- changes what any role can execute.
--
-- Frontend files that depend on this migration being live (grep across src/, 2026-11-03):
-- src/app/admin/customers/WaterHouseholdPanel.tsx, CustomerFormPage.tsx, CustomerDetailPage.tsx,
-- src/app/admin/service/TicketDetailPage.tsx, src/app/technician/OnSiteVisitPage.tsx,
-- JobDetailPage.tsx, HistoryDetailPage.tsx, src/services/customers.ts (setAddressWaterHousehold),
-- customerApp.ts, technician.ts, src/services/waterQuality.ts, src/hooks/useCustomers.ts,
-- useTechnician.ts, src/lib/validation/customer.ts (+ .test.ts), src/lib/validation/technician.ts,
-- src/lib/offline/outboxContract.ts (+ .test.ts), src/lib/i18n/en.json, ta.json,
-- src/types/database.ts. All of these already read/write these columns optimistically against
-- the TypeScript Database type (hand-patched ahead of the live schema, same convention as every
-- prior migration here) -- today's db -- they do not yet exist live, so any admin save that
-- reaches setAddressWaterHousehold / any technician screen reading these fields degrades
-- silently (Supabase returns the row without these keys / the update is rejected with
-- "column does not exist") until this migration is applied.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd
--                           (same pin already verified live today by the dup_contacts rehearsal;
--                           reused here since it is a property of the live org, re-checked fresh
--                           by THIS script at run time, not merely copied as a trusted result).
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. ALREADY-REGISTERED CHECK -- refuses if 20261103120000 is already registered.
--   3. NEW-COLUMN PRE-CHECK -- none of water_source/water_tds/water_ph/health_condition may
--                           already exist on public.addresses.
--   4. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of
--                           public.addresses, over REAL organisations only. Purely additive
--                           nullable columns never touch existing row content, so this must be
--                           identical after.
--   5. PIN              -- CR-tolerant sha256 of the embedded migration text must equal
--                           8f709f164ea5347fbb6ed99d6da72ad73dd52fb889527fcc5ae61c4aca84ac51,
--                           independently computed from the committed file
--                           (supabase/migrations/20261103120000_address_water_household_fields.sql)
--                           before this script was written.
--   6. RUN              -- EXECUTE the migration, verbatim (CR-tolerant).
--   7. REGISTER         -- INSERT the version row into supabase_migrations.schema_migrations,
--                           in the same transaction as the migration itself.
--   8. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      8a. all four columns now exist on public.addresses with the expected data_type and
--          is_nullable = 'YES' (water_source text, water_tds integer, water_ph numeric,
--          health_condition text);
--      8b. the real addresses fingerprint is unchanged from step 4.
--   9. On success, INSERT the one status row into pg_temp.water_household_apply_status.
--
-- Rollback: supabase/rollbacks/20261103120000_address_water_household_fields.rollback.sql
-- (four `drop column if exists`) -- already committed, reviewed alongside this script.

drop table if exists pg_temp.water_household_apply_status;
create temp table water_household_apply_status (
  version_registered         text,
  columns_exist               boolean,
  column_types_correct        boolean,
  addresses_fingerprint_unchanged boolean,
  applied_at                  timestamptz
);

do $apply$
declare
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
  v_expected_migration_hash text := '8f709f164ea5347fbb6ed99d6da72ad73dd52fb889527fcc5ae61c4aca84ac51';
  v_actual_hash text;
  v_already_registered boolean;
  v_pre_existing_count int;
  v_columns_exist boolean := false;
  v_types_correct boolean := false;
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
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. ALREADY-REGISTERED CHECK
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261103120000') into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: 20261103120000 is already registered in supabase_migrations.schema_migrations -- stop, nothing applied';
  end if;

  -- 3. NEW-COLUMN PRE-CHECK
  select count(*) into v_pre_existing_count
  from information_schema.columns
  where table_schema = 'public' and table_name = 'addresses'
    and column_name in ('water_source', 'water_tds', 'water_ph', 'health_condition');
  if v_pre_existing_count > 0 then
    raise exception 'APPLY_REFUSED: % of the 4 target column(s) already exist on public.addresses before this migration ran', v_pre_existing_count;
  end if;

  -- 4. REAL-TABLE FINGERPRINT (BEFORE)
  select count(*), md5(coalesce(string_agg(a.id::text || a.updated_at::text, '' order by a.id), ''))
    into v_addr_count_before, v_addr_md5_before
  from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  -- 5. PIN
  v_migration_text := $migration$-- Water & household step (2026-11-03): admin Customer form gets a new
-- review step capturing the primary address's water source/quality plus the
-- household's health condition, alongside the existing family-members list.
-- Mirrors 20261103090000_address_full_address_field.sql — nullable, additive
-- columns, no backfill, no RPC change (create_customer_with_details is left
-- untouched; a brand-new customer's primary address gets these written as a
-- small follow-up update, same pattern as setAddressZone).
alter table public.addresses add column if not exists water_source text;
alter table public.addresses add column if not exists water_tds integer;
alter table public.addresses add column if not exists water_ph numeric;
alter table public.addresses add column if not exists health_condition text;

comment on column public.addresses.water_source is
  'Added 2026-11-03 — free-text water source (e.g. Corporation, Borewater), captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.water_tds is
  'Added 2026-11-03 — measured TDS in ppm, captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.water_ph is
  'Added 2026-11-03 — measured pH, captured on the Water & household step of the admin Customer form.';
comment on column public.addresses.health_condition is
  'Added 2026-11-03 — free-text household health condition note, captured on the Water & household step of the admin Customer form.';
$migration$;

  v_actual_hash := encode(sha256(convert_to(replace(v_migration_text, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_hash;
  end if;

  -- 6. RUN
  execute replace(v_migration_text, E'\r', '');

  -- 7. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261103120000', 'address_water_household_fields', array[replace(v_migration_text, E'\r', '')]);

  -- 8a. columns exist with the expected types.
  select
    count(*) = 4,
    bool_and(
      (column_name = 'water_source' and data_type = 'text')
      or (column_name = 'water_tds' and data_type = 'integer')
      or (column_name = 'water_ph' and data_type = 'numeric')
      or (column_name = 'health_condition' and data_type = 'text')
    ) and bool_and(is_nullable = 'YES')
  into v_columns_exist, v_types_correct
  from information_schema.columns
  where table_schema = 'public' and table_name = 'addresses'
    and column_name in ('water_source', 'water_tds', 'water_ph', 'health_condition');

  if not v_columns_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 4 target columns exist on public.addresses after the migration ran';
  end if;
  if not v_types_correct then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or more of the 4 new columns has an unexpected data_type or is not nullable';
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
  insert into pg_temp.water_household_apply_status (
    version_registered, columns_exist, column_types_correct, addresses_fingerprint_unchanged, applied_at
  )
  values (
    '20261103120000', v_columns_exist, v_types_correct,
    (v_addr_count_after = v_addr_count_before and v_addr_md5_after = v_addr_md5_before),
    now()
  );
end
$apply$;

select * from pg_temp.water_household_apply_status;
