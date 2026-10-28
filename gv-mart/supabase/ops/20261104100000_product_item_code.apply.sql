-- GO APPLY script for migration 20261104100000_product_item_code.sql (P4 part 1: products.item_code
-- column + case-insensitive partial unique index), commit on pkg4/item-code.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c), and that the live rehearsal of this
-- exact migration (rehearsal_20261104100000_product_item_code.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only adds a brand-new nullable column (products.item_code) and a
-- partial unique index over it. No existing row has a value to conflict with (the column is new), and no
-- existing row's data changes. It creates no function and changes no grant.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only (ALTER TABLE ADD COLUMN takes an
--      ACCESS EXCLUSIVE lock on products, however briefly -- the rehearsal wrapper's own commit history
--      flags this explicitly).
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261104100000, refuse immediately.
--   4. NEW-OBJECT PRE-CHECK -- neither products.item_code nor the index
--      products_item_code_unique_idx may already exist.
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- products (id/org_id/name/price, excluding item_code, which this
--      migration adds), over REAL (non __TEST_) organisations only.
--   6. PIN          -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   7. RUN          -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   8. REGISTER     -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   9. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      9a. the column and the index both exist;
--      9b. the real products fingerprint is unchanged from step 5 -- this migration touches no table rows.
--   10. On success, INSERT the one status row into pg_temp.product_item_code_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.product_item_code_apply_status;
create temp table product_item_code_apply_status (
  migration_version              text,
  version_registered             boolean,
  column_and_index_exist         boolean,
  table_fingerprint_before       text,
  table_fingerprint_after        text,
  table_fingerprint_unchanged    boolean,
  applied_at                     timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := '117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261104100000';
  v_already_registered       boolean;
  v_column_exists            boolean;
  v_index_exists             boolean;
  v_objects_ok                boolean := true;
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p4a1$-- P4: an identification code per PRODUCT (spares already have one — `spares.sku`, 20260701090300). This is a
-- code SET by master in Inventory/Masters, printed on invoice and quotation lines — NOT a per-unit serial/IMEI.
-- Per-unit tracking (one row per physical unit, captured at sale and tied to the warranty) is a separate, larger
-- design and is explicitly held pending the owner's answer; nothing here anticipates it.
--
-- Same shape as spares.sku: plain nullable text, no DB-level check — sku itself has none either; the
-- alphanumeric/hyphen/underscore format is validated client-side only (ProductsTab.tsx), matching SparesTab.tsx's
-- own sku field exactly. Master-write only (products_write_master already covers this column — no RLS change).
--
-- A case-insensitive PARTIAL unique index: two products in the same org cannot share a code, but any number may
-- leave it null (not yet coded). Safe to add in this same migration — item_code is a brand-new column with no
-- existing rows to conflict (no backfill), so there is nothing for the index to reject at creation time.

alter table public.products
  add column item_code text;

comment on column public.products.item_code is
  'Master-set identification code for the product (not a per-unit serial). Printed on invoice/quotation lines alongside the item name.';

create unique index products_item_code_unique_idx on public.products (org_id, lower(item_code)) where item_code is not null;
$p4a1$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST (owner decision, 2026-10-28).
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied',
      v_migration_version;
  end if;

  -- 4. NEW-OBJECT PRE-CHECK -- neither the column nor the index may already exist.
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products' and column_name = 'item_code'
  ) into v_column_exists;
  if v_column_exists then
    raise exception 'APPLY_REFUSED: public.products.item_code already exists live before this migration ran';
  end if;
  if to_regclass('public.products_item_code_unique_idx') is not null then
    raise exception 'APPLY_REFUSED: public.products_item_code_unique_idx already exists live before this migration ran';
  end if;

  -- 5. REAL-TABLE FINGERPRINT (BEFORE) -- products, REAL organisations only, excluding item_code.
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
                     from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_before;

  -- 6. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 8. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'product_item_code', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9a. the column and the index both exist.
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products' and column_name = 'item_code'
  ) into v_column_exists;
  select (to_regclass('public.products_item_code_unique_idx') is not null) into v_index_exists;
  v_objects_ok := coalesce(v_column_exists, false) and coalesce(v_index_exists, false);
  if not v_objects_ok then
    raise exception 'APPLY_REFUSED: post-apply check failed -- products.item_code and/or products_item_code_unique_idx do not exist after the migration ran';
  end if;

  -- 9b. the real products fingerprint is unchanged -- this migration touches no table rows.
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
                     from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real products fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.product_item_code_apply_status (
    migration_version, version_registered, column_and_index_exist,
    table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_objects_ok,
    v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.product_item_code_apply_status;
