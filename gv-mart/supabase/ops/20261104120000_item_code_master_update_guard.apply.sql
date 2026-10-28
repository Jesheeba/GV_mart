-- GO APPLY script for migration 20261104120000_item_code_master_update_guard.sql (P4 part 3: defense-in-
-- depth master-only UPDATE guard on products.item_code), commit on pkg4/item-code.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- b5fac0cfb851f31735e1f02cec04e4ce22aab9e7a8176c51c15353ce6be66f4f), that P4 part 1 (20261104100000) has
-- ALREADY been applied for real (this script checks, see step 4), and that the live rehearsal of this
-- exact migration (rehearsal_20261104120000_item_code_master_update_guard.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration only creates one brand-new function
-- (guard_item_code_update(), via CREATE OR REPLACE -- which would silently overwrite a same-named
-- pre-existing function rather than erroring) and one brand-new BEFORE UPDATE OF item_code trigger on
-- products. It is defense-in-depth only: products_write_master already restricts every write on products
-- to master, so this trigger has nothing of its own to block under today's policy set. It writes no row.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261104120000, refuse immediately.
--   4. PREREQUISITE CHECK -- P4 part 1 (20261104100000) must already be registered, AND
--      products.item_code must actually exist (this migration's trigger fires BEFORE UPDATE OF
--      item_code, which requires the column to already exist).
--   5. NEW-OBJECT PRE-CHECK -- public.guard_item_code_update() must not already exist.
--   6. REAL-TABLE FINGERPRINT (BEFORE) -- products (id/org_id/name/price, same formula P4 part 1's apply
--      script used), over REAL (non __TEST_) organisations only.
--   7. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   8. PIN          -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   9. RUN          -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   10. REGISTER    -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   11. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      11a. the function exists and the trigger exists, fires BEFORE UPDATE OF item_code specifically;
--      11b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot;
--      11c. ABSOLUTE check -- anon/PUBLIC cannot execute guard_item_code_update(), independent of 11b
--          (the migration's own text already revokes this explicitly -- checked here as well, not
--          assumed);
--      11d. the real products fingerprint is unchanged from step 6.
--   12. On success, INSERT the one status row into pg_temp.item_code_master_update_guard_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.item_code_master_update_guard_apply_status;
create temp table item_code_master_update_guard_apply_status (
  migration_version              text,
  version_registered             boolean,
  function_and_trigger_exist     boolean,
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
  v_expected_migration_hash  text := 'b5fac0cfb851f31735e1f02cec04e4ce22aab9e7a8176c51c15353ce6be66f4f';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261104120000';
  v_already_registered       boolean;
  v_p4a1_registered          boolean;
  v_function_and_trigger_ok  boolean := true;
  v_anon_exec                boolean := false;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                text;
  v_fp_after                 text;
  v_embedded_migration       text := $p4a3$-- P4 part 3: a defense-in-depth UPDATE guard on products.item_code, same shape as guard_technician_tier_change /
-- tier_id_master_guard (20261001140000).
--
-- Today products_write_master already restricts EVERY write on products (insert/update/delete, every column,
-- item_code included) to master: `using (org_id = current_org_id() and is_master())` /
-- `with check (...)` (20260701091300_rls.sql). No role other than master can reach an UPDATE of this row at
-- all right now, so under today's policy set this trigger has nothing of its own to block that RLS does not
-- already block first.
--
-- It exists anyway, scoped to item_code only, for the same reason tier_id_master_guard exists even though
-- technicians_write_ops already gates technicians by org: that policy covers a WHOLE TABLE. If products_write_master
-- is ever loosened to let operation_admin (or any non-master role) edit other product fields — stock, pricing,
-- description — item_code does not silently come along for the ride; it stays master-only unless this trigger is
-- deliberately loosened too. Other columns on products are completely untouched by this migration; they remain
-- exactly as editable (or not) as products_write_master already makes them today.
--
-- SECURITY INVOKER (not SECURITY DEFINER, unlike tier_id_master_guard): the only thing evaluated is
-- public.is_master(), which is already SECURITY DEFINER and self-contained — this trigger needs no elevated
-- privilege of its own, and running as invoker means it can never do more than the session already could.
-- search_path is still pinned, as every function in this schema does.
--
-- auth.uid() is null for service-role / migration writes (and for anon, which per 20261016500000 has NO table
-- privilege on products at all — not UPDATE, not even SELECT — so an anon connection can never reach this trigger
-- in the first place; the auth.uid() is null bypass below is for service-role/migration writes only and is not a
-- path anon can use). Fires only when item_code actually changes value (BEFORE UPDATE OF item_code, plus an
-- explicit IS DISTINCT FROM so touching the column in the SET list without changing its value is still a no-op).

create or replace function public.guard_item_code_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.item_code is distinct from old.item_code and auth.uid() is not null and not public.is_master() then
    raise exception 'Only master can change a product''s item_code';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_item_code_update on public.products;
create trigger guard_item_code_update before update of item_code on public.products
  for each row execute function public.guard_item_code_update();

-- Explicit, even though a trigger function is invoked by the executor regardless of EXECUTE grants on it (and a
-- direct `select guard_item_code_update()` outside trigger context is already refused by Postgres itself,
-- "trigger functions can only be called as triggers") — belt-and-suspenders, matching this schema's convention of
-- not relying on a function's shape to keep it un-callable.
revoke all on function public.guard_item_code_update() from public, anon, authenticated;
$p4a3$;
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
  -- exist (this trigger fires BEFORE UPDATE OF item_code).
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

  -- 5. NEW-OBJECT PRE-CHECK -- public.guard_item_code_update() must not already exist.
  if to_regprocedure('public.guard_item_code_update()') is not null then
    raise exception 'APPLY_REFUSED: public.guard_item_code_update() already exists live before this migration ran';
  end if;

  -- 6. REAL-TABLE FINGERPRINT (BEFORE) -- products, REAL organisations only, same formula P4 part 1 used.
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
                     from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
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
  values (v_migration_version, 'item_code_master_update_guard', array[replace(v_embedded_migration, E'\r', '')]);

  -- 11a. the function exists and the trigger exists, fires BEFORE UPDATE OF item_code specifically.
  v_function_and_trigger_ok :=
    (to_regprocedure('public.guard_item_code_update()') is not null)
    and exists (
      select 1 from pg_trigger t
      where t.tgrelid = 'public.products'::regclass and t.tgname = 'guard_item_code_update' and not t.tgisinternal
        and (t.tgtype & 2) = 2 and (t.tgtype & 16) = 16
    );
  if not v_function_and_trigger_ok then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard_item_code_update() and/or its trigger are missing after the migration ran';
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

  -- 11c. ABSOLUTE check -- anon/PUBLIC cannot execute guard_item_code_update(), independent of 11b.
  select has_function_privilege('anon', 'public.guard_item_code_update()', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.guard_item_code_update() is executable by anon/PUBLIC';
  end if;

  -- 11d. the real products fingerprint is unchanged.
  select md5(coalesce((select string_agg(p.id::text || ':' || p.org_id::text || ':' || p.name || ':' || p.price::text, ',' order by p.id)
                     from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%')), ''))
         || '|' || (select count(*)::text from public.products p where p.org_id in (select o.id from public.organizations o where o.name not like '\_\_TEST\_%'))
    into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real products fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 12. Every step above passed -- record the one status row.
  insert into pg_temp.item_code_master_update_guard_apply_status (
    migration_version, version_registered, function_and_trigger_exist, function_executable_by_anon,
    newly_leaked_functions, table_fingerprint_before, table_fingerprint_after, table_fingerprint_unchanged,
    applied_at
  )
  values (
    v_migration_version, true, v_function_and_trigger_ok, v_anon_exec,
    v_newly_leaked, v_fp_before, v_fp_after, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.item_code_master_update_guard_apply_status;
