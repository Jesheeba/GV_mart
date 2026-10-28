-- GO APPLY script for migration 20261113100000_close_spare_handover_technician_rls_hole.sql (closes the
-- direct-write hole in spare_handovers / spare_handover_items: drops the FOR-ALL technician policies,
-- replaces them with SELECT-only, redefines confirm_spare_handover invoker -> definer), commit 007c972 on
-- feat/spare-handover-completion.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file (standing hard
-- rule: no DB access of any kind). The owner runs this by hand, after 11:00 IST, once satisfied the
-- sha256-pinned migration text embedded below is byte-for-byte the reviewed migration file (sha256
-- d582f42cd850986a7374333c60706d41973295deac5c710de9ad75dbc2b63778), and that the live rehearsal of this
-- exact migration (20261113100000_close_spare_handover_technician_rls_hole.rehearsal.sql) came back clean.
--
-- Structure: no top-level BEGIN;/COMMIT; -- a single standalone DO block run under autocommit is already
-- atomic. Three statements total: (1) CREATE TEMP TABLE for the status row, autocommitted on its own;
-- (2) the DO block itself; (3) a read-only SELECT from that temp table. Unlike the rehearsal wrapper, THIS
-- SCRIPT IS MEANT TO COMMIT -- no embedded test, no forced closing RAISE.
--
-- UPDATE/BACKFILL: NONE. This migration drops 2 FOR-ALL policies (spare_handovers_write_own_technician,
-- spare_handover_items_write_own_technician), creates 2 SELECT-only replacement policies with the
-- identical USING condition (so read access is unchanged), and redefines ONE existing function
-- (confirm_spare_handover: security invoker -> security definer, plus set search_path = public -- the
-- body and its ownership check are otherwise byte-for-byte the live function). No column, no table, no
-- existing admin-facing behaviour changes, and no table row is written by this migration.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must equal the
--      pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST (owner decision, 2026-10-28, applies to every GO APPLY
--      script in this release window).
--   3. ALREADY-REGISTERED CHECK -- if supabase_migrations.schema_migrations already has a row for version
--      20261113100000, refuse immediately.
--   4. LIVE-DEFINITION PRE-CHECK -- public.confirm_spare_handover(uuid,text,text) redefines an EXISTING
--      function (created by 20260702120000_technician_phase7_functions.sql, currently SECURITY INVOKER).
--      Pattern: recreate the pinned pre-migration original as pg_temp.confirm_spare_handover (never
--      touching the real function), compare md5(pg_get_functiondef(...)) of that pg_temp copy
--      (name-normalized) against the actually-live public function (also name-normalized) -- the same
--      technique this migration's own rehearsal wrapper uses, which never needs a probe-and-rollback
--      since the real function is never touched by the comparison itself.
--   5. NEW-OBJECT PRE-CHECK -- neither spare_handovers_select_own_technician nor
--      spare_handover_items_select_own_technician may already exist as policies.
--   6. REAL-DATA FINGERPRINT (BEFORE) -- counts of spare_handovers/spare_handover_items/
--      technician_stock_levels/spare_returns/notifications/organizations plus a checksum of
--      spare_handovers(id/status), over REAL organisations only -- the exact formula this migration's own
--      rehearsal wrapper used.
--   7. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   8. PIN         -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
--   9. RUN         -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   10. REGISTER   -- INSERT the version row into supabase_migrations.schema_migrations, in the same
--      transaction as the migration itself.
--   11. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      11a. both new SELECT-only policies exist, and the two old FOR-ALL policies are gone;
--      11b. confirm_spare_handover is now SECURITY DEFINER;
--      11c. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff it
--          against the BEFORE snapshot (this migration grants/revokes nothing, so expected empty, but
--          checked, not assumed);
--      11d. ABSOLUTE check -- anon/PUBLIC cannot execute confirm_spare_handover, independent of 11c
--          (the migration's own text already revokes-then-grants-to-authenticated-only; checked
--          independently here);
--      11e. the real fingerprint (same formula as step 6) is unchanged.
--   12. On success, INSERT the one status row into
--      pg_temp.close_spare_handover_technician_rls_hole_apply_status.
--
-- No test file is embedded and there is no rollback script invoked here: any rollback for this migration
-- is run by hand, outside this script, only if the owner decides afterwards to undo the change.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.close_spare_handover_technician_rls_hole_apply_status;
create temp table close_spare_handover_technician_rls_hole_apply_status (
  migration_version               text,
  version_registered              boolean,
  policies_correct                boolean,
  confirm_spare_handover_is_definer boolean,
  function_executable_by_anon     boolean,
  newly_leaked_functions          text[],
  data_fingerprint_before         text,
  data_fingerprint_after          text,
  data_fingerprint_unchanged      boolean,
  applied_at                      timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint          text;
  v_expected_migration_hash  text := 'd582f42cd850986a7374333c60706d41973295deac5c710de9ad75dbc2b63778';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261113100000';
  v_already_registered       boolean;
  v_pgtemp_def               text;
  v_live_def                 text;
  v_policies_ok               boolean;
  v_confirm_is_definer       boolean := false;
  v_anon_exec                boolean := false;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_fp_before                jsonb;
  v_fp_after                 jsonb;
  v_orig_csh_pgtemp          text := $OCSH_TEXT$create or replace function pg_temp.confirm_spare_handover(
  p_handover_id uuid,
  p_tech_sign_url text,
  p_admin_sign_url text
)
returns void
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'confirm_spare_handover: caller is not a technician';
  end if;
  if nullif(p_tech_sign_url, '') is null or nullif(p_admin_sign_url, '') is null then
    raise exception 'confirm_spare_handover: both technician and admin signatures are required';
  end if;

  update public.spare_handovers
    set tech_sign_url = p_tech_sign_url, admin_sign_url = p_admin_sign_url, status = 'confirmed'
    where id = p_handover_id and technician_id = v_tech_id;

  if not found then
    raise exception 'confirm_spare_handover: handover % not found for this technician', p_handover_id;
  end if;
end;
$$;
$OCSH_TEXT$;
  v_embedded_migration       text := $spmig1$-- Close the direct-write hole in spare_handovers / spare_handover_items (2026-10-27 review).
--
-- Found (same review that produced 20261114100000_spare_handover_completion_gaps.sql, but
-- deliberately left unfixed there as out of scope): spare_handovers_write_own_technician and
-- spare_handover_items_write_own_technician (both in 20260701091300_rls.sql) are `FOR ALL`
-- policies keyed only on technician_id = current_technician_id(). `FOR ALL` covers
-- SELECT/INSERT/UPDATE/DELETE, so a technician holding nothing but the app's normal
-- authenticated session could INSERT a fake spare_handovers row (and spare_handover_items
-- lines) directly against PostgREST, bypassing create_spare_handover() entirely -- no
-- warehouse decrement, no technician_stock_levels increment, no inventory_movements row.
-- Every stock-movement side effect create_spare_handover() exists to enforce is skippable
-- this way. The same review checked spare_returns and technician_stock_levels for the same
-- pattern and found neither has it: both tables only ever got technician_stock_levels_select_own /
-- spare_returns_select_own (SELECT-only, 20260921110000_technician_van_stock_schema.sql) plus
-- technician_stock_levels_write_ops / spare_returns_write_ops (FOR ALL, is_ops_staff() only,
-- 20260921121000_technician_stock_write_policy.sql) -- no technician write policy exists on
-- either table to begin with, so this migration makes NO changes to them. Confirmed by
-- grepping every `create policy ... on (technician_stock_levels|spare_returns|
-- spare_return_items)` in supabase/migrations/ -- see the review bundle for the exact grep.
--
-- Precedent: 20261016130000_ratings_no_direct_writes.sql closed the identical FOR-ALL-to-
-- technician shape on `ratings`. That fix also revoked INSERT/UPDATE/DELETE/TRUNCATE on
-- ratings from authenticated entirely, because EVERY legitimate ratings writer (including
-- ops staff) already went through a SECURITY DEFINER function. That is NOT true here:
-- create_spare_handover() and admin_sign_spare_handover() (both ops-staff-only) are
-- `security invoker`, by design (20260921120000's and 20260702200100's own comments: ops
-- writes are authorized by RLS + an explicit is_ops_staff() check, not a bypassing definer),
-- and they run as the calling ops-staff member under the single shared Postgres role
-- `authenticated` (there is no separate DB role per app role -- master/operation_admin/
-- technician/sales_admin is only a profiles.role column). Revoking the table-level INSERT/
-- UPDATE/DELETE grant from `authenticated` would silently break those two ops-staff flows
-- along with every other `authenticated`-held session, technician or not. So unlike the
-- ratings fix, this migration touches ONLY the RLS policies, not the table-level GRANTs:
-- spare_handovers_write_ops / spare_handover_items_write_ops (FOR ALL, is_ops_staff()) are
-- left completely untouched, and master/operation_admin keep writing exactly as they do today
-- (create_spare_handover, admin_sign_spare_handover, both unchanged).
--
-- One real complication the ratings precedent did not have: confirm_spare_handover (the
-- technician's own signature-confirmation RPC, 20260702120000_technician_phase7_functions.sql)
-- is ALSO `security invoker`, and its own comment there says so explicitly: "Plain update
-- would already pass `spare_handovers_write_own_technician` RLS, but centralising the 'both
-- signatures must be present' rule server-side avoids re-implementing it in every offline-sync
-- retry path." That means confirm_spare_handover's UPDATE relies on the very policy this
-- migration drops -- naively dropping spare_handovers_write_own_technician with no
-- replacement would make every technician's confirm_spare_handover call silently update 0 rows
-- (Postgres RLS denies an UPDATE by excluding the row from the USING-filtered scan, not by
-- raising an error -- there is no pre-existing row to violate a WITH CHECK against), which
-- confirm_spare_handover already turns into a raised "handover % not found for this
-- technician" exception via its own `if not found` check. So confirm_spare_handover is
-- redefined below, verbatim except `security invoker` -> `security definer` (bypassing RLS,
-- the same way report_spare_handover_discrepancy and create_service_invoice already do) plus
-- `set search_path = public` (it had none before; safe to add since every reference inside is
-- already schema-qualified with `public.`). Its existing `where ... and technician_id =
-- v_tech_id` / `if not found then raise` ownership check is untouched and is now the ONLY
-- gate on this write (no longer backed up by RLS too) -- that check was already correct and
-- already the one actually doing the ownership enforcement day to day; RLS was redundant with
-- it, never the sole guard.
--
-- Net result for a technician: SELECT on their own spare_handovers / spare_handover_items rows
-- is preserved exactly (new SELECT-only policies, identical USING condition to the dropped
-- FOR ALL policies -- nothing about read access changes). Direct INSERT/UPDATE/DELETE against
-- either table is gone. Every legitimate technician write still works, unchanged, because every
-- one of them already went through an RPC: create_spare_handover (ops-only, unaffected),
-- confirm_spare_handover (now definer, fixed here), report_spare_handover_discrepancy (already
-- definer, unaffected by any of this).
--
-- No data is touched. No column, table, or existing admin-facing behavior changes.

drop policy if exists spare_handovers_write_own_technician on public.spare_handovers;

create policy spare_handovers_select_own_technician on public.spare_handovers for select
  using (public.spare_handovers.technician_id = public.current_technician_id());

drop policy if exists spare_handover_items_write_own_technician on public.spare_handover_items;

create policy spare_handover_items_select_own_technician on public.spare_handover_items for select
  using (
    exists (
      select 1 from public.spare_handovers h
      where h.id = public.spare_handover_items.handover_id
        and h.technician_id = public.current_technician_id()
    )
  );

-- confirm_spare_handover: security invoker -> security definer (see header for why). Body is
-- otherwise byte-for-byte the live function from 20260702120000_technician_phase7_functions.sql.
create or replace function public.confirm_spare_handover(
  p_handover_id uuid,
  p_tech_sign_url text,
  p_admin_sign_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'confirm_spare_handover: caller is not a technician';
  end if;
  if nullif(p_tech_sign_url, '') is null or nullif(p_admin_sign_url, '') is null then
    raise exception 'confirm_spare_handover: both technician and admin signatures are required';
  end if;

  update public.spare_handovers
    set tech_sign_url = p_tech_sign_url, admin_sign_url = p_admin_sign_url, status = 'confirmed'
    where id = p_handover_id and technician_id = v_tech_id;

  if not found then
    raise exception 'confirm_spare_handover: handover % not found for this technician', p_handover_id;
  end if;
end;
$$;

revoke all on function public.confirm_spare_handover(uuid, text, text) from public, anon, authenticated;
grant execute on function public.confirm_spare_handover(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
$spmig1$;
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

  -- 4. LIVE-DEFINITION PRE-CHECK -- public.confirm_spare_handover(uuid,text,text) must still be
  -- its pre-migration (security invoker) definition. Recreate the pinned original as a pg_temp
  -- copy (never touching the real function), compare name-normalized pg_get_functiondef output.
  execute replace(v_orig_csh_pgtemp, E'\r', '');
  v_pgtemp_def := regexp_replace(
    pg_get_functiondef('pg_temp.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'pg_temp(_[0-9]+)?\.confirm_spare_handover', 'FN', 'g');
  v_live_def := regexp_replace(
    pg_get_functiondef('public.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'public\.confirm_spare_handover', 'FN', 'g');
  if md5(v_pgtemp_def) <> md5(v_live_def) then
    raise exception 'APPLY_REFUSED: live public.confirm_spare_handover(uuid,text,text) differs from its pre-migration definition -- something else changed it since this script was approved';
  end if;

  -- 5. NEW-OBJECT PRE-CHECK -- neither replacement policy may already exist.
  if exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handovers'::regclass and pol.polname = 'spare_handovers_select_own_technician') then
    raise exception 'APPLY_REFUSED: policy spare_handovers_select_own_technician already exists live before this migration ran';
  end if;
  if exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handover_items'::regclass and pol.polname = 'spare_handover_items_select_own_technician') then
    raise exception 'APPLY_REFUSED: policy spare_handover_items_select_own_technician already exists live before this migration ran';
  end if;

  -- 6. REAL-DATA FINGERPRINT (BEFORE) -- same formula this migration's own rehearsal used.
  select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) into v_fp_before;

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
  values (v_migration_version, 'close_spare_handover_technician_rls_hole', array[replace(v_embedded_migration, E'\r', '')]);

  -- 11a. both new policies exist; both old FOR-ALL policies are gone.
  v_policies_ok :=
    exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handovers'::regclass and pol.polname = 'spare_handovers_select_own_technician')
    and exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handover_items'::regclass and pol.polname = 'spare_handover_items_select_own_technician')
    and not exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handovers'::regclass and pol.polname = 'spare_handovers_write_own_technician')
    and not exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handover_items'::regclass and pol.polname = 'spare_handover_items_write_own_technician');
  if not v_policies_ok then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the policy set on spare_handovers/spare_handover_items does not match the expected post-migration shape';
  end if;

  -- 11b. confirm_spare_handover is now SECURITY DEFINER.
  select prosecdef into v_confirm_is_definer from pg_proc where oid = 'public.confirm_spare_handover(uuid,text,text)'::regprocedure;
  if not coalesce(v_confirm_is_definer, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.confirm_spare_handover(uuid,text,text) is not SECURITY DEFINER after the migration ran';
  end if;

  -- 11c. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
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

  -- 11d. ABSOLUTE check -- anon/PUBLIC cannot execute confirm_spare_handover, independent of 11c.
  select has_function_privilege('anon', 'public.confirm_spare_handover(uuid, text, text)', 'EXECUTE') into v_anon_exec;
  if v_anon_exec then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.confirm_spare_handover is executable by anon/PUBLIC';
  end if;

  -- 11e. the real fingerprint (same formula as step 6) is unchanged.
  select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) into v_fp_after;

  if v_fp_after is distinct from v_fp_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real fingerprint changed (before %, after %)',
      v_fp_before, v_fp_after;
  end if;

  -- 12. Every step above passed -- record the one status row.
  insert into pg_temp.close_spare_handover_technician_rls_hole_apply_status (
    migration_version, version_registered, policies_correct, confirm_spare_handover_is_definer,
    function_executable_by_anon, newly_leaked_functions,
    data_fingerprint_before, data_fingerprint_after, data_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_policies_ok, v_confirm_is_definer,
    v_anon_exec, v_newly_leaked,
    v_fp_before::text, v_fp_after::text, (v_fp_after = v_fp_before), now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.close_spare_handover_technician_rls_hole_apply_status;
