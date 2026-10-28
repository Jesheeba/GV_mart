-- GO APPLY script for migration 20261104110000_invoice_quotation_item_code_snapshot.sql (P4 part 2:
-- invoice_items/quotation_items.item_code snapshot columns + the trigger that stamps them), commit on
-- pkg4/item-code.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- 4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d), that P4 part 1 (20261104100000) has
-- ALREADY been applied for real (this script checks, see step 4), and that the live rehearsal of this
-- exact migration (rehearsal_20261104110000_invoice_quotation_item_code_snapshot.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration adds two brand-new nullable columns (invoice_items.item_code,
-- quotation_items.item_code), one brand-new function (_stamp_item_code, via CREATE OR REPLACE -- which,
-- unlike bare CREATE, would silently overwrite a same-named pre-existing function rather than erroring),
-- and two brand-new BEFORE INSERT OR UPDATE triggers (one per table, both named aa_stamp_item_code). No
-- existing row's data changes -- the new columns start NULL and are only ever stamped on a NEW row by the
-- trigger going forward.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261104110000, refuse immediately.
--   4. PREREQUISITE CHECK -- P4 part 1 (20261104100000) must already be registered, AND
--      products.item_code must actually exist (the new trigger function reads it) -- a technical, not
--      just logical, dependency.
--   5. NEW-OBJECT PRE-CHECK -- neither invoice_items.item_code nor quotation_items.item_code may already
--      exist, and public._stamp_item_code() must not already exist.
--   6. REAL-TABLE FINGERPRINT (BEFORE) -- invoice_items + quotation_items (id/org_id/invoice_id-or-
--      quotation_id/item_type/item_id/qty/price, excluding item_code, which this migration adds), over
--      REAL (non __TEST_) organisations only.
--   7. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   8. PIN          -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   9. RUN          -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   10. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   11. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      11a. both new columns exist, the function exists, and both triggers exist and fire BEFORE
--          INSERT OR UPDATE;
--      11b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      11c. ABSOLUTE check -- anon/PUBLIC cannot execute _stamp_item_code(), independent of 11b;
--      11d. the real invoice_items/quotation_items fingerprint is unchanged from step 6.
--   12. On success, INSERT the one status row into
--      pg_temp.invoice_quotation_item_code_snapshot_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.invoice_quotation_item_code_snapshot_apply_status;
create temp table invoice_quotation_item_code_snapshot_apply_status (
  migration_version              text,
  version_registered             boolean,
  new_objects_exist              boolean,
  function_executable_by_anon    boolean,
  newly_leaked_functions         text[],
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
  v_expected_migration_hash  text := '4acedd9092e5fc40009709dcda9f65405c29c314913341ff32e24e6f25678a8d';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261104110000';
  v_already_registered       boolean;
  v_p4a1_registered          boolean;
  v_new_objects_exist        boolean := true;
  v_anon_exec                boolean := false;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p4a2$-- P4 part 2: a SNAPSHOT of the item's identification code on each invoice/quotation LINE, stamped at line-creation
-- time — not read from the live catalog at print time (that was the first cut of this package; replaced here).
--
-- invoice_items and quotation_items reference their item by (item_type, item_id): item_type is the enum
-- 'product' | 'spare' (20260701090000_extensions_and_enums.sql), item_id is a bare uuid with NO foreign key —
-- it is polymorphic, pointing at products.id or spares.id depending on item_type (confirmed: neither table's
-- Relationships list in the generated types names item_id; only org_id/invoice_id/quotation_id are real FKs).
-- There is no name-only matching anywhere in this path.
--
-- A BEFORE INSERT trigger on both tables resolves item_code from the catalog the moment the line is created:
-- products.item_code when item_type = 'product', spares.sku when item_type = 'spare'. It ALWAYS overwrites
-- whatever the client sent in that column (the same pattern _meeting_issue_attribution and other
-- stamp-from-session triggers in this schema use for their own column) so a line's code cannot be spoofed by a
-- direct insert.
--
-- The SAME trigger also fires BEFORE UPDATE, where it does the opposite: new.item_code := old.item_code,
-- unconditionally. A line's code is a snapshot of what was true at creation; it must never be rewritten by a
-- later UPDATE — not by a client-supplied value, and not by re-deriving it even if item_type/item_id also change
-- in that UPDATE (invoice_items_write_sales/quotation_items_write_sales already allow a staff UPDATE of other
-- columns on these rows, and that must not have this side effect).
--
-- create_sale and create_quotation are NOT edited — both insert into these tables with plain INSERT statements,
-- so the trigger fires under them exactly as it does under a direct client insert; nothing in either RPC's own
-- body needs to change. No backfill: existing rows (there are none yet in this org, since item_code on products
-- itself was only added in the previous migration) get the column but it is only ever stamped on a NEW row.
--
-- SECURITY INVOKER: a plain read of products/spares, which is already org-wide SELECT for everyone
-- (products_select_org / spares_select_org), so no elevated privilege is needed regardless of which path
-- (create_sale's own SECURITY DEFINER context, or a direct insert_sales write under invoice_items_write_sales)
-- fires the trigger.

alter table public.invoice_items add column item_code text;
alter table public.quotation_items add column item_code text;

comment on column public.invoice_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';
comment on column public.quotation_items.item_code is
  'Snapshot of products.item_code or spares.sku at the moment this line was created. Stamped by a trigger, never read live.';

create or replace function public._stamp_item_code()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    new.item_code := old.item_code;
    return new;
  end if;
  if new.item_type = 'product' then
    select p.item_code into new.item_code from public.products p where p.id = new.item_id;
  elsif new.item_type = 'spare' then
    select s.sku into new.item_code from public.spares s where s.id = new.item_id;
  else
    new.item_code := null;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_stamp_item_code on public.invoice_items;
create trigger aa_stamp_item_code
  before insert or update on public.invoice_items
  for each row execute function public._stamp_item_code();

drop trigger if exists aa_stamp_item_code on public.quotation_items;
create trigger aa_stamp_item_code
  before insert or update on public.quotation_items
  for each row execute function public._stamp_item_code();
$p4a2$;
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

  -- 4. PREREQUISITE CHECK -- P4 part 1 must already be applied, AND products.item_code must actually
  -- exist (the new trigger function reads it).
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261104100000') into v_p4a1_registered;
  if not v_p4a1_registered then
    raise exception 'APPLY_REFUSED: prerequisite P4 part 1 (20261104100000) is not yet registered in supabase_migrations.schema_migrations -- apply it first';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products' and column_name = 'item_code'
  ) then
    raise exception 'APPLY_REFUSED: prerequisite check failed -- public.products.item_code does not exist; P4 part 1 does not appear to be live despite its version row';
  end if;

  -- 5. NEW-OBJECT PRE-CHECK.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'invoice_items' and column_name = 'item_code'
  ) then
    raise exception 'APPLY_REFUSED: public.invoice_items.item_code already exists live before this migration ran';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'quotation_items' and column_name = 'item_code'
  ) then
    raise exception 'APPLY_REFUSED: public.quotation_items.item_code already exists live before this migration ran';
  end if;
  if to_regprocedure('public._stamp_item_code()') is not null then
    raise exception 'APPLY_REFUSED: public._stamp_item_code() already exists live before this migration ran';
  end if;

  -- 6. REAL-TABLE FINGERPRINT (BEFORE) -- invoice_items + quotation_items, REAL organisations only,
  -- excluding item_code.
  select md5(coalesce((select string_agg(i.id::text || ':' || i.org_id::text || ':' || i.invoice_id::text || ':' || i.item_type::text || ':' || i.item_id::text || ':' || i.qty::text || ':' || i.price::text, ',' order by i.id)
                     from public.invoice_items i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || md5(coalesce((select string_agg(q.id::text || ':' || q.org_id::text || ':' || q.quotation_id::text || ':' || q.item_type::text || ':' || q.item_id::text || ':' || q.qty::text || ':' || q.price::text, ',' order by q.id)
                     from public.quotation_items q where q.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
    into v_fp_before;

  -- 7. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 8. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 9. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 10. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'invoice_quotation_item_code_snapshot', array[replace(v_embedded_migration, E'\r', '')]);

  -- 11a. both new columns, the function, and both triggers exist and fire BEFORE INSERT OR UPDATE.
  v_new_objects_exist :=
    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoice_items' and column_name = 'item_code')
    and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'quotation_items' and column_name = 'item_code')
    and to_regprocedure('public._stamp_item_code()') is not null
    and exists (select 1 from pg_trigger t where t.tgrelid = 'public.invoice_items'::regclass and t.tgname = 'aa_stamp_item_code' and not t.tgisinternal and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4 and (t.tgtype & 16) = 16)
    and exists (select 1 from pg_trigger t where t.tgrelid = 'public.quotation_items'::regclass and t.tgname = 'aa_stamp_item_code' and not t.tgisinternal and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4 and (t.tgtype & 16) = 16);

  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or more of the new columns/function/triggers are missing after the migration ran';
  end if;

  -- 11b. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (
    select unnest(v_leaked_after) as x
    except
    select unnest(v_leaked_before)
  ) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 11c. ABSOLUTE check -- anon/PUBLIC cannot execute _stamp_item_code(), independent of 11b.
  select has_function_privilege('anon', 'public._stamp_item_code()', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public._stamp_item_code() is executable by anon/PUBLIC';
  end if;

  -- 11d. the real invoice_items/quotation_items fingerprint is unchanged.
  select md5(coalesce((select string_agg(i.id::text || ':' || i.org_id::text || ':' || i.invoice_id::text || ':' || i.item_type::text || ':' || i.item_id::text || ':' || i.qty::text || ':' || i.price::text, ',' order by i.id)
                     from public.invoice_items i where i.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || md5(coalesce((select string_agg(q.id::text || ':' || q.org_id::text || ':' || q.quotation_id::text || ':' || q.item_type::text || ':' || q.item_id::text || ':' || q.qty::text || ':' || q.price::text, ',' order by q.id)
                     from public.quotation_items q where q.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real invoice_items/quotation_items fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 12. Every step above passed -- record the one status row.
  insert into pg_temp.invoice_quotation_item_code_snapshot_apply_status (
    migration_version, version_registered, new_objects_exist, function_executable_by_anon,
    newly_leaked_functions, table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_anon_exec,
    v_newly_leaked, v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.invoice_quotation_item_code_snapshot_apply_status;
