-- CHAINED rehearsal wrapper proving the TRUE apply order: 20261113100000
-- (close_spare_handover_technician_rls_hole) THEN 20261114100000
-- (spare_handover_completion_gaps), both migrations' own test files, and a NEW test
-- (spare_handover_chain_post_migration.test.sql) that re-checks the technician-facing RPCs
-- and the closed RLS hole once BOTH migrations are live together, not just each one alone.
--
-- Supersedes running 20261113100000's and 20261114100000's rehearsal wrappers separately as
-- the pre-apply proof for this pair: the sibling 20261113100000 rehearsal wrapper is left in
-- place for standalone use (e.g. rehearsing just that migration in isolation), but this file
-- is the one rehearsal path that proves the real end-to-end order a live apply will actually
-- follow.
--
-- NOT run against any database by this agent. Intended usage: a reviewer with real DB access
-- runs this file after 11:00 IST (owner decision, 2026-10-28); it refuses before that, refuses if the lock budget (5s,
-- set first thing, before the time gate even) is exceeded, refuses if any of the five
-- embedded files (two migrations, two of their own tests, one new chained test) no longer
-- matches its pinned sha256 (re-pin after any edit to any of them), refuses if any of the
-- three functions this pair of migrations touches (confirm_spare_handover,
-- create_spare_handover, create_service_invoice) no longer matches its pinned ORIGINAL live
-- body (someone else changed it since this migration pair was written -- never trust a
-- pinned text blindly), otherwise rehearses migration 1, test 1, migration 2, test 2, and the
-- new chained test, all inside ONE DO block with no top-level BEGIN/COMMIT/SAVEPOINT/
-- ROLLBACK, takes a relative fingerprint of the real organisation both before and after, and
-- ends in an unconditional RAISE so nothing here ever persists -- every DDL change and every
-- __TEST_ row from all three test runs is rolled back by that final raise.
--
-- The fingerprint checksum deliberately uses only columns that exist BEFORE either migration
-- runs (id, technician_id, status) in both the before and after blocks, kept byte-identical
-- in shape to each other -- NOT spare_handovers.given_by, which 20261114100000 adds partway
-- through this very rehearsal. A checksum using given_by would itself fail against a real
-- live database (today's live spare_handovers has no such column) before the migration even
-- gets a chance to add it. This is the fix for the 2026-10-27 review's fingerprint-bug finding.
--
-- Each embedded file is run via EXECUTE (SPI_execute accepts a multi-statement string) -- this
-- file never concatenates any of them into one file on disk; they are embedded separately here
-- only for the rehearsal to run them in sequence.
do $rehearsal$
declare
  v_now_ist time;
  v_lock_timeout_hit boolean := false;
  v_mig1_sha256 text := 'd582f42cd850986a7374333c60706d41973295deac5c710de9ad75dbc2b63778';
  v_test1_sha256 text := '8ff8b144a0c77819066cc023ed151d5d14bca7955d7366153322fb7b14f7c5f3';
  v_mig2_sha256 text := '08c734722e49ac7f47225f0547ac90d5bc9a075e1747a70e5aeac3715cab3bea';
  v_test2_sha256 text := 'b58dce801eb8890328c31be9e77de3a481a509bf1fcddeadaa9257e4bbc185b2';
  v_newtest_sha256 text := '905d597bd95c0e28778444d436b96c74e48360e205abc09a0b2180b66d40f83d';
  v_mig1_text text;
  v_test1_text text;
  v_mig2_text text;
  v_test2_text text;
  v_newtest_text text;
  v_orig_confirm_pgtemp text;
  v_orig_create_pgtemp text;
  v_orig_csi_pgtemp text;
  v_org_fp text;
  v_live_def text;
  v_pgtemp_def text;
  v_fp_before jsonb;
  v_fp_after jsonb;
  v_test1_results text;
  v_test2_results text;
  v_newtest_results text;
begin
  -- ── 0. lock budget -- first executed statement, before even the time gate, so a real run
  --      can never hang on a lock. This rehearsal touches spare_handovers / spare_handover_items
  --      (DROP/CREATE POLICY needs a brief exclusive-ish lock) and three functions.
  perform set_config('lock_timeout', '5s', true);

  -- ── 1. time gate ──────────────────────────────────────────────────────────────────────
  v_now_ist := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  if v_now_ist < time '11:00' then
    raise exception 'rehearsal refused: run only after 11:00 IST (Asia/Kolkata) -- current IST time is %', v_now_ist;
  end if;

  -- ── 1b. organisation fingerprint pin -- the very first check after the lock budget and
  --       time gate, before anything else including the sha256 file pins below. This literal
  --       value was supplied by the reviewer who has real DB access; this rehearsal cannot and
  --       does not attempt to verify or second-guess it -- it is wired in exactly as given.
  select md5(o.id::text || '|' || o.name) into v_org_fp
    from public.organizations o
    where o.name not like '\_\_TEST\_%' escape '\'
    order by o.created_at asc, o.id asc
    limit 1;
  if v_org_fp is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- ── 2. embedded text: migration 1, test 1, migration 2, test 2, new chained test ───────
  v_mig1_text := $CHAIN_MIG1$-- Close the direct-write hole in spare_handovers / spare_handover_items (2026-10-27 review).
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
$CHAIN_MIG1$;

  v_test1_text := $CHAIN_TEST1$-- Rolled-back DB tests for 20261113100000_close_spare_handover_technician_rls_hole.sql.
-- Run with the migration applied in the same transaction (the runner concatenates it in front
-- of this file -- never concatenate them into one file). Throwaway __TEST_ org only.
-- NOT run against any database by this agent -- this file has never been executed.
--
-- A note on SQLSTATE 42501 and UPDATE/DELETE: this migration deliberately does NOT revoke the
-- table-level INSERT/UPDATE/DELETE grant on spare_handovers/spare_handover_items from
-- `authenticated` (see the migration's header for why -- ops-staff's invoker RPCs need it).
-- That means a technician's blocked INSERT still raises a genuine RLS violation
-- (SQLSTATE 42501, "new row violates row-level security policy") because INSERT has no prior
-- row to filter -- WITH CHECK is evaluated against the new row and fails outright. A blocked
-- UPDATE/DELETE is different: Postgres RLS filters an UPDATE/DELETE's candidate rows via each
-- applicable policy's USING clause *before* the statement runs, the same as an extra WHERE
-- condition -- if zero rows satisfy any USING clause for that command, the statement simply
-- matches 0 rows and returns normally (no exception, no SQLSTATE). This is exactly why
-- confirm_spare_handover and admin_sign_spare_handover already carry their own
-- `if not found then raise` checks instead of relying on an RLS exception. So: the INSERT
-- case below is asserted via catch + SQLSTATE 42501 (the literal exception-raising case);
-- the UPDATE/DELETE cases are asserted via GET DIAGNOSTICS row_count = 0 (the literal
-- silently-matches-nothing case) -- both are "blocked", just via the two different mechanisms
-- Postgres actually uses for them. See the review bundle for the longer explanation.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_cust uuid; v_spare1 uuid; v_handover_id uuid; v_item_id uuid; v_rows integer;
  v_status text; v_tech_sign text; v_admin_sign text;
  fp_handovers_before text; fp_handovers_after text;
begin
  -- fingerprint real (non-test) data before touching anything, re-checked at the end.
  select md5(coalesce(string_agg(id::text || status, ',' order by id), '')) into fp_handovers_before
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_spare_handover_rls_hole') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000002') returning id into v_cust;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare RLS', 'T-SPR1', 50) returning id into v_spare1;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare1, 10, 'warehouse');

  -- ── grants: table-level privilege is intentionally unchanged for authenticated ──────────
  perform pg_temp.chk('authenticated table-level INSERT privilege on spare_handovers is unchanged (ops still needs it)',
    has_table_privilege('authenticated', 'public.spare_handovers', 'insert'));
  perform pg_temp.chk('authenticated table-level UPDATE privilege on spare_handovers is unchanged (ops still needs it)',
    has_table_privilege('authenticated', 'public.spare_handovers', 'update'));

  -- ── the ops-staff RPC path is unaffected: create_spare_handover still works end to end ──
  perform pg_temp.as_user(v_ops);
  v_handover_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 3)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('ops-staff create_spare_handover still creates a hand-over', v_handover_id is not null);
  select id into v_item_id from public.spare_handover_items where handover_id = v_handover_id and spare_id = v_spare1;
  perform pg_temp.chk('hand-over item line created', v_item_id is not null);

  -- admin_sign_spare_handover (also security invoker, relies on spare_handovers_write_ops,
  -- which this migration never touches) still works for ops.
  perform pg_temp.as_user(v_ops);
  perform public.admin_sign_spare_handover(v_handover_id, 'data:image/png;base64,__TEST_admin_sig');
  perform pg_temp.as_pg();
  select status, admin_sign_url into v_status, v_admin_sign from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('admin_sign_spare_handover (ops, unaffected) still sets admin_sign_url', v_admin_sign is not null and v_status = 'pending');

  -- ── technician read access is preserved exactly (new SELECT-only policy) ────────────────
  perform pg_temp.as_user(v_tp1);
  v_rows := null;
  select count(*) into v_rows from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('owning technician can still SELECT their own hand-over', v_rows = 1, v_rows::text);
  v_rows := null;
  select count(*) into v_rows from public.spare_handover_items where id = v_item_id;
  perform pg_temp.chk('owning technician can still SELECT their own hand-over item', v_rows = 1, v_rows::text);
  perform pg_temp.as_pg();

  -- a different technician still cannot see it (unchanged, pre-existing behavior).
  perform pg_temp.as_user(v_tp2);
  v_rows := null;
  select count(*) into v_rows from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('another technician still cannot SELECT it', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  -- ── the hole: direct writes by a technician are now blocked ─────────────────────────────
  -- INSERT: no row pre-exists to filter, so WITH CHECK is evaluated and fails outright -- a
  -- real RLS violation, SQLSTATE 42501.
  perform pg_temp.as_user(v_tp1);
  begin
    insert into public.spare_handovers (org_id, technician_id, date, status)
      values (v_org, v_tech1, current_date, 'pending');
    perform pg_temp.chk('technician direct INSERT into spare_handovers is blocked', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('technician direct INSERT into spare_handovers is blocked', true, sqlerrm);
  end;

  begin
    insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (v_org, v_handover_id, v_spare1, 999);
    perform pg_temp.chk('technician direct INSERT into spare_handover_items is blocked', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('technician direct INSERT into spare_handover_items is blocked', true, sqlerrm);
  end;

  -- UPDATE/DELETE: the row is invisible to the UPDATE/DELETE scan under any policy applicable
  -- to a technician, so the statement affects 0 rows and raises nothing -- see the header note.
  update public.spare_handovers set status = 'confirmed' where id = v_handover_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician direct UPDATE on spare_handovers matches 0 rows', v_rows = 0, v_rows::text);

  update public.spare_handover_items set qty_given = 1 where id = v_item_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician direct UPDATE on spare_handover_items matches 0 rows', v_rows = 0, v_rows::text);

  delete from public.spare_handovers where id = v_handover_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician direct DELETE on spare_handovers matches 0 rows', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  -- confirm the row is genuinely untouched by all of the above (status still 'pending' from
  -- admin_sign_spare_handover above, not 'confirmed'; still exists at all).
  select status into v_status from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('hand-over row untouched by the refused direct writes', v_status = 'pending', coalesce(v_status, '<deleted>'));

  -- ── technician_stock_levels / spare_returns: confirmed they never had this pattern, and
  -- still don't (regression check, not a change made by this migration) ───────────────────
  perform pg_temp.as_user(v_tp1);
  begin
    insert into public.technician_stock_levels (org_id, technician_id, item_type, item_id, stock_qty)
      values (v_org, v_tech1, 'spare', v_spare1, 100);
    perform pg_temp.chk('technician direct INSERT into technician_stock_levels is blocked (unchanged)', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('technician direct INSERT into technician_stock_levels is blocked (unchanged)', true, sqlerrm);
  end;
  begin
    insert into public.spare_returns (org_id, technician_id, date) values (v_org, v_tech1, current_date);
    perform pg_temp.chk('technician direct INSERT into spare_returns is blocked (unchanged)', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('technician direct INSERT into spare_returns is blocked (unchanged)', true, sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ── confirm_spare_handover (now security definer) still works end to end for the owning
  -- technician, and is still refused for a handover that isn't theirs ─────────────────────
  -- Schema-qualified by oid, not proname: once the live-definition pre-check has created
  -- pg_temp.confirm_spare_handover (which persists for the rest of the session), a bare
  -- `proname = 'confirm_spare_handover'` matches BOTH it and public.confirm_spare_handover,
  -- and the scalar subquery raises "more than one row returned" (SQLSTATE 21000) -- found by
  -- the reviewer, since both rehearsal wrappers run exactly that pre-check before this test.
  perform pg_temp.chk('confirm_spare_handover is now security definer',
    (select prosecdef from pg_proc where oid = 'public.confirm_spare_handover(uuid,text,text)'::regprocedure));
  perform pg_temp.chk('anon cannot execute confirm_spare_handover',
    not has_function_privilege('anon', 'public.confirm_spare_handover(uuid,text,text)', 'execute'));
  perform pg_temp.chk('authenticated can execute confirm_spare_handover',
    has_function_privilege('authenticated', 'public.confirm_spare_handover(uuid,text,text)', 'execute'));

  perform pg_temp.as_user(v_tp1);
  perform public.confirm_spare_handover(v_handover_id, 'data:image/png;base64,__TEST_tech_sig', 'data:image/png;base64,__TEST_admin_sig_2');
  perform pg_temp.as_pg();
  select status, tech_sign_url into v_status, v_tech_sign from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('confirm_spare_handover (now definer) still flips status to confirmed', v_status = 'confirmed', coalesce(v_status, '<null>'));
  perform pg_temp.chk('confirm_spare_handover still records the technician signature', v_tech_sign is not null);

  perform pg_temp.as_user(v_tp2);
  begin
    perform public.confirm_spare_handover(v_handover_id, 'x', 'y');
    perform pg_temp.chk('a different technician still cannot confirm this hand-over', false);
  exception when others then
    perform pg_temp.chk('a different technician still cannot confirm this hand-over', sqlerrm like '%not found for this technician%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ── real-org data is untouched ─────────────────────────────────────────────────────────
  select md5(coalesce(string_agg(id::text || status, ',' order by id), '')) into fp_handovers_after
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real spare_handovers rows unchanged', fp_handovers_before = fp_handovers_after);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$CHAIN_TEST1$;

  v_mig2_text := $CHAIN_MIG2$-- Spare hand-over completion: closes the 4 PARTIAL gaps found by the 2026-10-27 audit
-- (SPARE_HANDOVER_AUDIT_2026_10_27.md) against requirements 2, 3, 6, 7 of the spare
-- hand-over / technician-stock / return feature. Requirements 1 ("master/operation_admin,
-- not sales_admin, hand to one technician"), 4 ("job use deducts the technician's own
-- stock, never double-deducts central") and 5 ("return moves tech -> central, confirmed by
-- master/operation_admin") were already MET on main and are UNTOUCHED here.
--
-- NOT APPLIED to any database. Nothing in this file has been run against a live project.
--
-- Backward compatibility: every new column is nullable with no default that changes
-- existing semantics, and no existing row needs a backfill:
--   - spare_handovers.given_by: NULL for every row created before this column existed --
--     there is no source of truth for who actually gave a past hand-over beyond the
--     (unrelated) admin_sign_url image, so NULL correctly means "not recorded."
--   - spare_handover_items.received_qty / dispute_note: NULL means "no dispute raised,"
--     which is the true state of every existing row (nobody could raise a dispute before
--     this migration -- the feature didn't exist).
-- Both redefined functions (create_spare_handover, create_service_invoice) keep their exact
-- existing signatures, so every existing caller (admin web, technician app) keeps working
-- unchanged; the only behavior delta is the one new column write / one new notification.
--
-- Requirement 2 ("who gave it" + "a disputed quantity is flagged to staff"):
--   - spare_handovers.given_by, set by create_spare_handover from auth.uid() (the calling
--     ops-staff member) on both the normal-path and conflict-retry INSERT.
--   - spare_handover_items.received_qty / dispute_note, written only by the new
--     report_spare_handover_discrepancy() RPC below.
--   - report_spare_handover_discrepancy(): technician-only. Verifies the item belongs to a
--     hand-over addressed to the calling technician, records the disputed quantity, and
--     inserts a notifications row targeted at role='operation_admin' -- which
--     notifications_select_own_role (20260715100000_service_visits_customer_rls_and_
--     notification_role_fix.sql) already widens to master too via public.is_master(), the
--     same pattern submit_rating uses for its low_rating notification
--     (20260702120000_technician_phase7_functions.sql) -- so both master and operation_admin
--     see it, sales_admin does not (matches requirement 1's role boundary).
--
-- Requirement 6 ("a shortfall must be flagged for staff, not lost silently"):
--   create_service_invoice's existing 'service_use_shortfall' branch (first introduced
--   20260921140000_service_use_van_stock_and_shortfall_tagging.sql, unchanged verbatim
--   through the live 20261016160000_rental_generator_scheduling.sql body) already tags the
--   inventory_movements row correctly -- it was never silently lost from the books -- but
--   nothing ever surfaced that tag to staff. This redefinition adds exactly one notification
--   insert, gated on `v_movement_reason = 'service_use_shortfall'`, right after the existing
--   movement insert. Every other line is byte-for-byte the live body; see the rehearsal
--   wrapper (20261114100000_spare_handover_completion_gaps.rehearsal.sql) for the embedded
--   original used to verify that claim against whatever is actually live before this is ever
--   applied.
--
-- Requirement 3 ("a technician sees only his own stock") / 7 ("staff see a ledger: handed
-- over, used, returned, balance"): technician_spare_ledger is a brand-new VIEW, not a change
-- to any existing table -- zero migration risk to existing rows. It is `security_invoker`
-- (Postgres defaults a view to running with the view OWNER's privileges on the underlying
-- tables unless this is set explicitly -- pinned here on purpose, same pattern as the live
-- v_referral_events view, 20261016140000_referral_overview_read_model.sql), so visibility is
-- governed entirely by the RLS already on inventory_movements (staff-only:
-- inventory_movements_select_staff, 20260701091300_rls.sql) and technician_stock_levels
-- (staff-all / own-technician: 20260921110000_technician_van_stock_schema.sql) -- no new RLS
-- policy is needed or added, and no caller gets access to anything they couldn't already
-- query directly. The technician's own "My spares" screen (Step C) reads
-- technician_stock_levels directly instead (its existing technician_stock_levels_select_own
-- policy already scopes a technician to their own balance; the ledger view itself resolves
-- to zero rows for a technician today because inventory_movements has no technician-visible
-- policy, so it's a staff-only view as the requirement asks for).

-- ── requirement 2: given_by + dispute columns ──────────────────────────────────────────────
alter table public.spare_handovers
  add column given_by uuid references public.profiles (id) on delete set null;

alter table public.spare_handover_items
  add column received_qty integer,
  add column dispute_note text;

alter table public.spare_handover_items
  add constraint spare_handover_items_received_qty_check check (received_qty is null or received_qty >= 0);

comment on column public.spare_handovers.given_by is
  'Profile id of the master/operation_admin who created this hand-over via create_spare_handover(). NULL for rows created before 2026-11-14 -- no source of truth to backfill from.';
comment on column public.spare_handover_items.received_qty is
  'Set by report_spare_handover_discrepancy() when the technician says the physical quantity received differs from qty_given. NULL = no dispute raised.';
comment on column public.spare_handover_items.dispute_note is
  'Optional free-text note accompanying a disputed received_qty.';

-- ── requirement 2: create_spare_handover now records given_by ─────────────────────────────
-- Original live body (20260921120000_spare_handover_per_technician_stock.sql) reproduced
-- verbatim except: (a) `given_by` added to both header INSERTs' column/value lists, bound to
-- auth.uid(); (b) `set search_path = public` added -- the live function has none, which is
-- safe to tighten since every reference inside is already schema-qualified with `public.`.
create or replace function public.create_spare_handover(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_given}, ...]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_handover_id uuid;
  v_item record;
  v_new_stock integer;
  v_have integer;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_handover: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_handover: caller is not ops staff';
  end if;

  insert into public.spare_handovers (org_id, technician_id, date, status, given_by)
  values (p_org_id, p_technician_id, p_date, 'pending', auth.uid())
  on conflict do nothing
  returning id into v_handover_id;

  -- date has no unique constraint (a technician can have more than one handover per day in
  -- principle), so on_conflict above never actually fires today -- kept defensive, unchanged
  -- from the live body.
  if v_handover_id is null then
    insert into public.spare_handovers (org_id, technician_id, date, status, given_by)
    values (p_org_id, p_technician_id, p_date, 'pending', auth.uid())
    returning id into v_handover_id;
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_given integer)
    loop
      if v_item.qty_given is null or v_item.qty_given <= 0 then
        continue;
      end if;
      insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (p_org_id, v_handover_id, v_item.spare_id, v_item.qty_given);

      -- Warehouse-side decrement, unchanged conditional UPDATE.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty_given
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'warehouse' and stock_qty >= v_item.qty_given
        returning stock_qty into v_new_stock;

      if v_new_stock is null then
        select stock_qty into v_have
          from public.inventory
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse';
        raise exception 'create_spare_handover: insufficient warehouse stock for spare % (need %, have %)',
          v_item.spare_id, v_item.qty_given, coalesce(v_have, 0);
      end if;

      -- Per-technician van-side increment, unchanged.
      insert into public.technician_stock_levels (org_id, technician_id, item_type, item_id, stock_qty)
      values (p_org_id, p_technician_id, 'spare', v_item.spare_id, v_item.qty_given)
      on conflict (org_id, technician_id, item_type, item_id)
      do update set stock_qty = technician_stock_levels.stock_qty + excluded.stock_qty, updated_at = now();

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty_given, 'spare_handover', v_handover_id, p_technician_id);
    end loop;
  end if;

  return v_handover_id;
end;
$$;

revoke all on function public.create_spare_handover(uuid, uuid, date, jsonb) from public, anon, authenticated;
grant execute on function public.create_spare_handover(uuid, uuid, date, jsonb) to authenticated;

-- ── requirement 2: technician-side dispute RPC (new) ───────────────────────────────────────
-- SECURITY DEFINER is required here (not a stylistic choice): the technician must be able to
-- raise a staff notification, and notifications_insert_ops (20260701091300_rls.sql) only
-- allows is_ops_staff() to INSERT into public.notifications directly -- same justification
-- submit_rating already uses for its own low_rating notification
-- (20260702120000_technician_phase7_functions.sql). No current_user/session_user check is
-- used inside -- caller identity comes from public.current_technician_id() (auth.uid()-based)
-- exactly like every other technician-only RPC in this codebase.
create or replace function public.report_spare_handover_discrepancy(
  p_org_id uuid,
  p_item_id uuid,
  p_received_qty integer,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_item public.spare_handover_items;
  v_handover public.spare_handovers;
  v_tech_name text;
  v_spare_name text;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'report_spare_handover_discrepancy: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'report_spare_handover_discrepancy: org mismatch';
  end if;
  if p_received_qty is null or p_received_qty < 0 then
    raise exception 'report_spare_handover_discrepancy: received quantity must be zero or more';
  end if;

  select * into v_item from public.spare_handover_items where id = p_item_id and org_id = p_org_id;
  if v_item is null then
    raise exception 'report_spare_handover_discrepancy: item % not found', p_item_id;
  end if;

  select * into v_handover from public.spare_handovers where id = v_item.handover_id and org_id = p_org_id;
  if v_handover is null or v_handover.technician_id is distinct from v_tech_id then
    raise exception 'report_spare_handover_discrepancy: item % does not belong to the calling technician', p_item_id;
  end if;
  if p_received_qty = v_item.qty_given then
    raise exception 'report_spare_handover_discrepancy: received quantity matches the handed-over quantity, nothing to flag';
  end if;

  update public.spare_handover_items
    set received_qty = p_received_qty, dispute_note = nullif(btrim(coalesce(p_note, '')), '')
    where id = p_item_id;

  select p.full_name into v_tech_name
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  select name into v_spare_name from public.spares where id = v_item.spare_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'spare_handover_disputed', 'Spare hand-over quantity disputed',
    format('%s reports receiving %s of %s on the %s hand-over (handed over: %s).',
      coalesce(v_tech_name, 'A technician'), p_received_qty, coalesce(v_spare_name, 'a spare'),
      to_char(v_handover.date, 'DD Mon YYYY'), v_item.qty_given),
    v_handover.id
  );
end;
$$;

revoke all on function public.report_spare_handover_discrepancy(uuid, uuid, integer, text) from public, anon, authenticated;
grant execute on function public.report_spare_handover_discrepancy(uuid, uuid, integer, text) to authenticated;

-- ── requirement 6: create_service_invoice now flags a shortfall to staff ──────────────────
-- Original live body: 20261016160000_rental_generator_scheduling.sql lines 147-450 (same
-- signature, SECURITY DEFINER, SET search_path TO 'public'). Reproduced verbatim below except
-- for the single new `if v_movement_reason = 'service_use_shortfall' then insert into
-- notifications ... end if;` block added right after the existing inventory_movements insert
-- inside the spares loop. See this migration's own header and the rehearsal wrapper for the
-- exact-match proof against the live function before this is ever applied.
create or replace function public.create_service_invoice(p_org_id uuid, p_visit_id uuid, p_service_charge numeric, p_discount_percent numeric, p_spares jsonb, p_payment_method payment_method, p_txn_id text, p_payment_description text, p_is_chargeable boolean, p_amount_paid numeric default null::numeric, p_installations jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_movement_reason text;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
  v_rental_contract rental_contracts;
  v_rental_plan rental_plans;
  v_rental_interval_months integer;
  v_rental_visit_date date;
  v_rental_ticket_id uuid;
  v_rental_address_id uuid;
  v_install record; -- INSTALLATION TRACKING
  v_credit_qty integer;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'create_service_invoice: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_service_invoice: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null then
    raise exception 'create_service_invoice: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'create_service_invoice: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket is null then
    raise exception 'create_service_invoice: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_service_invoice: no settings row for org %', p_org_id;
  end if;

  -- A completed ticket is never invoiced (or credited) twice. The same technician repeating the call (offline-queue replay)
  -- gets the existing invoice back and nothing else is written; anyone else gets an error.
  if v_ticket.status = 'completed' then
    if v_ticket.invoice_id is not null and v_visit.technician_id = v_tech_id then
      return jsonb_build_object('invoice_id', v_ticket.invoice_id,
        'total', (select i.total from public.invoices i where i.id = v_ticket.invoice_id),
        'approval_id', null, 'already_completed', true);
    end if;
    raise exception 'create_service_invoice: ticket % is already completed', v_ticket.id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      if v_item.qty is null or v_item.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for spare %', v_item.spare_id;
      end if;
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      if v_price is null then
        raise exception 'create_service_invoice: spare % not found in org %', v_item.spare_id, p_org_id;
      end if;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      if p_is_chargeable or not v_is_spare_covered then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid
  ) returning * into v_invoice;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      -- This technician's own van balance first (was the pooled, org-wide
      -- `inventory` location='van' row - see this migration's header).
      update public.technician_stock_levels
        set stock_qty = stock_qty - v_item.qty, updated_at = now()
        where org_id = p_org_id and technician_id = v_tech_id
          and item_type = 'spare' and item_id = v_item.spare_id and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;

      if v_new_stock is not null then
        v_movement_reason := 'service_use_van';
      else
        -- Van didn't cover it (never handed over, or not enough) - fall
        -- back to warehouse, same conditional UPDATE as before, but now
        -- tagged so Group 5 reporting can flag the shortfall distinctly
        -- from a normal van deduction.
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
        v_movement_reason := 'service_use_shortfall';
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, v_movement_reason, p_visit_id, v_tech_id);

      -- NEW (requirement 6): a shortfall must be flagged for staff, not just tagged in the
      -- ledger. role='operation_admin' reaches master too via notifications_select_own_role's
      -- is_master() widening -- sales_admin, correctly, does not see it.
      if v_movement_reason = 'service_use_shortfall' then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        select p_org_id, 'operation_admin', 'spare_use_shortfall', 'Spare used with no recorded van stock',
          format('%s used %s x %s on a job without enough recorded van stock; drawn from the warehouse instead. Consider a hand-over.',
            coalesce(p.full_name, 'A technician'), v_item.qty, coalesce(s.name, 'a spare')),
          p_visit_id
        from public.technicians t
        join public.profiles p on p.id = t.profile_id
        left join public.spares s on s.id = v_item.spare_id
        where t.id = v_tech_id;
      end if;
    end loop;
  end if;

  -- INSTALLATION TRACKING: distinct from spares - logs which products were
  -- newly installed on this visit, purely for incentive counting (no
  -- invoice line, no stock movement - the product itself was already sold/
  -- stocked through its own path; this just credits the technician).
  if p_installations is not null and jsonb_array_length(p_installations) > 0 then
    for v_install in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
    loop
      if v_install.qty is null or v_install.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for installed product %', v_install.product_id;
      end if;
      if not exists (select 1 from public.products where id = v_install.product_id and org_id = p_org_id) then
        raise exception 'create_service_invoice: product % not found in org %', v_install.product_id, p_org_id;
      end if;

      insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty)
      values (p_org_id, p_visit_id, v_tech_id, v_install.product_id, v_install.qty);
    end loop;
  end if;

  -- Installation incentive: the ticket's per-unit charge (a master-editable snapshot) x units logged for the ticket's
  -- product, minimum 1. Created PENDING; the master approves it before Compute counts it. One credit per ticket+technician.
  if v_ticket.type = 'installation' and v_ticket.product_id is not null and coalesce(v_ticket.installation_charge_snapshot, 0) > 0 then
    select greatest(1, coalesce(sum(il.qty), 0))::integer into v_credit_qty
    from public.installations_logged il
    where il.visit_id = p_visit_id and il.product_id = v_ticket.product_id;
    insert into public.installation_incentive_credits (org_id, ticket_id, visit_id, technician_id, product_id, qty, unit_amount, amount, status)
    values (p_org_id, v_ticket.id, p_visit_id, v_tech_id, v_ticket.product_id, v_credit_qty,
            v_ticket.installation_charge_snapshot, v_ticket.installation_charge_snapshot * v_credit_qty, 'pending')
    on conflict (ticket_id, technician_id) do nothing;
    if found then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (p_org_id, 'master', 'installation_credit_pending', 'Installation incentive to approve',
              format('Installation completed: incentive of %s (%s unit(s)) is waiting for your approval.',
                     v_ticket.installation_charge_snapshot * v_credit_qty, v_credit_qty), v_ticket.id);
    end if;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    update public.amc_contracts
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if v_ticket.type = 'warranty' and v_ticket.warranty_id is not null then
    update public.warranties
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.warranty_id = v_ticket.warranty_id
          and st.type = 'warranty'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.warranty_id;
  end if;

  if v_ticket.type = 'rental' and v_ticket.rental_contract_id is not null then
    select * into v_rental_contract from public.rental_contracts where id = v_ticket.rental_contract_id;
    if v_rental_contract.status = 'active' then
      select * into v_rental_plan from public.rental_plans where id = v_rental_contract.plan_id;
      -- next visit: round(12 / visits_per_year) months from today (was integer division), rolled to a working day
      v_rental_interval_months := greatest(1, public._visit_month_offset(v_rental_plan.visits_per_year, 1));
      v_rental_visit_date := public._visit_working_day(p_org_id, ((now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_rental_interval_months))::date);
      v_rental_address_id := coalesce(v_rental_contract.address_id, v_ticket.address_id);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, rental_contract_id
      ) values (
        p_org_id, v_rental_contract.customer_id, v_rental_address_id, v_rental_contract.product_id,
        'Rental scheduled service', v_rental_plan.name, 'rental', 'normal', 'open', 'walk_in', v_rental_contract.id
      )
      returning id into v_rental_ticket_id;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
      values (p_org_id, v_rental_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_rental_visit_date),
              public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

      perform public._auto_assign_ticket_internal(v_rental_ticket_id, p_org_id, p_skip_rating_logic => true);

      update public.rental_contracts set next_service_date = v_rental_visit_date where id = v_rental_contract.id;
    end if;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if (now() at time zone 'Asia/Kolkata')::time >= v_settings.work_end then
    update public.attendance
    set shift_end_prompt_pending = true
    where technician_id = v_tech_id and org_id = p_org_id
      and date = (now() at time zone 'Asia/Kolkata')::date;

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select p_org_id, p.id, 'shift_end_prompt', 'Shift end reached',
      format('Your shift ended at %s. Reply to continue or check out.', to_char(v_settings.work_end, 'HH12:MI AM')), v_invoice.id
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  else
    perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$function$;

revoke all on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric, jsonb) to authenticated;

-- ── requirement 3 + 7: per-technician/per-spare staff ledger (new view) ───────────────────
-- security_invoker = on, same pattern as the live v_referral_events
-- (20261016140000_referral_overview_read_model.sql): visibility is entirely delegated to the
-- RLS already on inventory_movements (staff-only) and technician_stock_levels
-- (staff-all / own-technician). A technician querying this view sees zero rows today (their
-- RLS grants no access to inventory_movements at all) -- which is correct, since this is the
-- STAFF ledger; the technician's own balance comes from technician_stock_levels directly
-- (Step C's "My spares" screen), already covered by technician_stock_levels_select_own.
create view public.technician_spare_ledger
with (security_invoker = on) as
select
  m.org_id,
  m.technician_id,
  t.profile_id,
  p.full_name as technician_name,
  m.item_id as spare_id,
  s.name as spare_name,
  s.sku as spare_sku,
  coalesce(sum(case when m.reason = 'spare_handover' then -m.change_qty else 0 end), 0)::integer as qty_handed_over,
  coalesce(sum(case when m.reason in ('service_use_van', 'service_use_shortfall') then -m.change_qty else 0 end), 0)::integer as qty_used,
  coalesce(sum(case when m.reason = 'return' then m.change_qty else 0 end), 0)::integer as qty_returned,
  coalesce(tsl.stock_qty, 0) as balance
from public.inventory_movements m
join public.technicians t on t.id = m.technician_id
join public.profiles p on p.id = t.profile_id
join public.spares s on s.id = m.item_id
left join public.technician_stock_levels tsl
  on tsl.org_id = m.org_id and tsl.technician_id = m.technician_id
 and tsl.item_type = 'spare' and tsl.item_id = m.item_id
where m.item_type = 'spare' and m.technician_id is not null
group by m.org_id, m.technician_id, t.profile_id, p.full_name, m.item_id, s.name, s.sku, tsl.stock_qty;

revoke all on public.technician_spare_ledger from public, anon;
grant select on public.technician_spare_ledger to authenticated, service_role;

comment on view public.technician_spare_ledger is
  'Staff-facing ledger: per technician/spare, handed-over/used/returned totals plus current balance. Visibility is entirely driven by invoker RLS on inventory_movements (staff-only) and technician_stock_levels (staff-all/own) -- no RLS on the view itself.';

notify pgrst, 'reload schema';
$CHAIN_MIG2$;

  v_test2_text := $CHAIN_TEST2$-- Rolled-back DB tests for 20261114100000_spare_handover_completion_gaps.sql.
-- Run with the migration applied in the same transaction (the runner concatenates it in
-- front of this file -- never concatenate them into one file). Throwaway __TEST_ org only.
-- NOT run against any database by this agent -- this file has never been executed.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid; v_sales uuid;
  v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_cust uuid; v_spare1 uuid; v_spare2 uuid; v_spare3 uuid; v_tk uuid; v_visit uuid;
  v_handover_id uuid; v_item1_id uuid; v_item_check uuid;
  v_given_by uuid; v_received_qty integer; v_dispute_note text;
  v_notif_count integer; v_notif_role text; v_rows integer;
  v_wh1 integer; v_wh2 integer; v_wh2_after integer;
  v_ledger_handed integer; v_ledger_used integer; v_ledger_returned integer; v_ledger_balance integer;
  v_ledger_rowcount integer;
  v_handover3_id uuid; v_tk3a uuid; v_visit3a uuid; v_tk3b uuid; v_visit3b uuid; v_return3_id uuid;
  fp_handovers_before text; fp_handovers_after text; fp_notif_before bigint; fp_notif_after bigint;
begin
  -- fingerprint real (non-test) data before touching anything, re-checked at the end.
  select md5(coalesce(string_agg(id::text || coalesce(given_by::text,'') , ',' order by id), '')) into fp_handovers_before
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into fp_notif_before from public.notifications
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_spare_handover_gaps') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000001') returning id into v_cust;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare One', 'T-SP1', 100) returning id into v_spare1;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare Two', 'T-SP2', 200) returning id into v_spare2;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare1, 20, 'warehouse');
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare2, 10, 'warehouse');

  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ ticket') returning id into v_tk;
  insert into public.service_visits (org_id, ticket_id, technician_id) values (v_org, v_tk, v_tech1) returning id into v_visit;

  -- ── requirement 2: given_by ────────────────────────────────────────────────────────────
  perform pg_temp.as_user(v_ops);
  v_handover_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 5)));
  perform pg_temp.as_pg();
  select given_by into v_given_by from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('create_spare_handover records given_by = calling ops staff', v_given_by = v_ops, v_given_by::text);
  select id into v_item1_id from public.spare_handover_items where handover_id = v_handover_id and spare_id = v_spare1;
  perform pg_temp.chk('hand-over item line created', v_item1_id is not null);

  select stock_qty into v_wh1 from public.inventory where org_id = v_org and item_type = 'spare' and item_id = v_spare1 and location = 'warehouse';
  perform pg_temp.chk('warehouse decremented by the hand-over (unchanged behavior)', v_wh1 = 15, v_wh1::text);

  -- sales_admin may not hand over spares (requirement 1, unchanged -- re-verified here since
  -- this migration redefines create_spare_handover).
  perform pg_temp.as_user(v_sales);
  begin
    perform public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 1)));
    perform pg_temp.chk('sales_admin cannot create a hand-over', false);
  exception when others then
    perform pg_temp.chk('sales_admin cannot create a hand-over', sqlerrm like '%not ops staff%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ── requirement 2: dispute flagging ────────────────────────────────────────────────────
  perform pg_temp.as_user(v_tp1);
  perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 3, '__TEST_ only received 3');
  perform pg_temp.as_pg();
  select received_qty, dispute_note into v_received_qty, v_dispute_note from public.spare_handover_items where id = v_item1_id;
  perform pg_temp.chk('dispute recorded on the item', v_received_qty = 3 and v_dispute_note = '__TEST_ only received 3');
  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  perform pg_temp.chk('staff notified of the dispute', v_notif_count = 1, v_notif_count::text);

  -- read back the dispute notification row itself (not just count(*)) and confirm its role.
  v_notif_role := null;
  select role into v_notif_role from public.notifications
    where org_id = v_org and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  perform pg_temp.chk('dispute notification row read back with role = operation_admin', v_notif_role = 'operation_admin', coalesce(v_notif_role, '<null>'));

  -- sales_admin cannot read this notification at all (RLS silently returns zero rows, no
  -- exception -- same pattern as the other RLS zero-row checks in this file).
  perform pg_temp.as_user(v_sales);
  v_notif_role := null;
  select role into v_notif_role from public.notifications
    where org_id = v_org and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('sales_admin sees zero rows for the dispute notification (RLS)', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  -- disputing with received_qty equal to the original qty_given is refused as a no-op
  -- (the comparison is always against qty_given, so this is refused on every call, not just
  -- the first).
  perform pg_temp.as_user(v_tp1);
  begin
    perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 5, 'matches qty_given');
    perform pg_temp.chk('disputing with received_qty = qty_given is refused', false);
  exception when others then
    perform pg_temp.chk('disputing with received_qty = qty_given is refused', sqlerrm like '%nothing to flag%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- another technician cannot dispute someone else's item.
  perform pg_temp.as_user(v_tp2);
  begin
    perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 1, 'not mine');
    perform pg_temp.chk('technician2 cannot dispute technician1''s item', false);
  exception when others then
    perform pg_temp.chk('technician2 cannot dispute technician1''s item', sqlerrm like '%does not belong to the calling technician%', sqlerrm);
  end;
  -- ── requirement 3: a technician cannot even SELECT another technician's hand-over item
  -- (RLS filters it out silently -- zero rows, no exception).
  v_item_check := null;
  select id into v_item_check from public.spare_handover_items where id = v_item1_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician2 sees zero rows for technician1''s hand-over item (RLS)', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  -- technician1 can still see (and only) their own item.
  perform pg_temp.as_user(v_tp1);
  v_item_check := null;
  select id into v_item_check from public.spare_handover_items where id = v_item1_id;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('technician1 can see their own hand-over item', v_rows = 1);
  perform pg_temp.as_pg();

  -- ── requirement 6: a service-use shortfall (no recorded van stock for spare2) is flagged
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(
    v_org, v_visit, 0, 0, jsonb_build_array(jsonb_build_object('spare_id', v_spare2, 'qty', 2)),
    'cash'::payment_method, null, null, true
  );
  perform pg_temp.as_pg();

  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_use_shortfall' and ref_id = v_visit;
  perform pg_temp.chk('staff notified of the service-use shortfall', v_notif_count = 1, v_notif_count::text);

  -- read back the shortfall notification row itself (not just count(*)) and confirm its role.
  v_notif_role := null;
  select role into v_notif_role from public.notifications
    where org_id = v_org and type = 'spare_use_shortfall' and ref_id = v_visit;
  perform pg_temp.chk('shortfall notification row read back with role = operation_admin', v_notif_role = 'operation_admin', coalesce(v_notif_role, '<null>'));

  -- sales_admin cannot read this notification either (RLS silently returns zero rows).
  perform pg_temp.as_user(v_sales);
  v_notif_role := null;
  select role into v_notif_role from public.notifications
    where org_id = v_org and type = 'spare_use_shortfall' and ref_id = v_visit;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('sales_admin sees zero rows for the shortfall notification (RLS)', v_rows = 0, v_rows::text);
  perform pg_temp.as_pg();

  perform pg_temp.chk('inventory_movements tags the shortfall correctly (unchanged behavior)',
    exists (select 1 from public.inventory_movements where org_id = v_org and item_id = v_spare2 and technician_id = v_tech1 and reason = 'service_use_shortfall' and change_qty = -2));
  select stock_qty into v_wh2_after from public.inventory where org_id = v_org and item_type = 'spare' and item_id = v_spare2 and location = 'warehouse';
  perform pg_temp.chk('warehouse decremented exactly once for the shortfall, not twice (requirement 4, unchanged)', v_wh2_after = 8, v_wh2_after::text);

  -- ── requirement 7: staff ledger aggregates handed-over / used / returned / balance ───────
  perform pg_temp.as_user(v_ops);
  select qty_handed_over, qty_used, qty_returned, balance
    into v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance
    from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1 and spare_id = v_spare1;
  perform pg_temp.chk('ledger: spare1 handed over = 5, used = 0, balance = 5',
    v_ledger_handed = 5 and v_ledger_used = 0 and v_ledger_returned = 0 and v_ledger_balance = 5,
    format('handed=%s used=%s returned=%s balance=%s', v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance));

  select qty_handed_over, qty_used, qty_returned, balance
    into v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance
    from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1 and spare_id = v_spare2;
  perform pg_temp.chk('ledger: spare2 used = 2 (never handed over, balance stays 0)',
    v_ledger_handed = 0 and v_ledger_used = 2 and v_ledger_returned = 0 and v_ledger_balance = 0,
    format('handed=%s used=%s returned=%s balance=%s', v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance));

  -- sales_admin is staff too (is_staff() includes it) and sees the same ledger rows.
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales);
  select count(*) into v_ledger_rowcount from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1;
  perform pg_temp.chk('sales_admin (staff) can read the ledger', v_ledger_rowcount = 2, v_ledger_rowcount::text);
  perform pg_temp.as_pg();

  -- a technician gets zero rows from the staff ledger (inventory_movements grants them no
  -- SELECT at all) -- the technician's own balance comes from technician_stock_levels
  -- directly (the "My spares" screen), not from this view.
  perform pg_temp.as_user(v_tp1);
  select count(*) into v_ledger_rowcount from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1;
  perform pg_temp.chk('technician sees zero rows on the staff ledger (RLS)', v_ledger_rowcount = 0, v_ledger_rowcount::text);
  select stock_qty into v_rows from public.technician_stock_levels where org_id = v_org and technician_id = v_tech1 and item_type = 'spare' and item_id = v_spare1;
  perform pg_temp.chk('technician still reads their own balance directly from technician_stock_levels', v_rows = 5, v_rows::text);
  perform pg_temp.as_pg();

  -- ── third spare: full handover -> use(van) -> use(shortfall) -> return cycle, proving the
  -- ledger aggregates all four movement reasons together correctly ──────────────────────────
  -- Numbers below (handover 5, use #1 qty=3, use #2 qty=4, return qty=2) replace the
  -- reviewer's literal 10/3/2, which does not compose: a 3-unit use against a van balance of
  -- 10 never forces the shortfall branch, and returning 2 once the van has already been drawn
  -- down to 0 would itself trip create_spare_return's no-negative-balance guard. 5/3/4/2 is
  -- reachable end to end: van 5 -> (use 3, van branch) -> 2 -> (use 4, van insufficient,
  -- shortfall branch, van unchanged) -> 2 -> (return 2, exactly covers it) -> 0.
  -- create_service_invoice marks its ticket 'completed' and refuses a second call on the same
  -- ticket, so the two uses below are on two separate tickets/visits for the same technician.
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare Three', 'T-SP3', 150) returning id into v_spare3;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare3, 20, 'warehouse');

  perform pg_temp.as_user(v_ops);
  v_handover3_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare3, 'qty_given', 5)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('spare3: hand-over of 5 created', v_handover3_id is not null);

  -- use #1: qty=3, van has 5 -> covered entirely by the van branch (van 5 -> 2).
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ ticket spare3a') returning id into v_tk3a;
  insert into public.service_visits (org_id, ticket_id, technician_id) values (v_org, v_tk3a, v_tech1) returning id into v_visit3a;
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(
    v_org, v_visit3a, 0, 0, jsonb_build_array(jsonb_build_object('spare_id', v_spare3, 'qty', 3)),
    'cash'::payment_method, null, null, true
  );
  perform pg_temp.as_pg();
  perform pg_temp.chk('spare3: use #1 (qty=3) tagged as a van use (unchanged behavior)',
    exists (select 1 from public.inventory_movements where org_id = v_org and item_id = v_spare3 and technician_id = v_tech1 and reason = 'service_use_van' and change_qty = -3));
  select stock_qty into v_rows from public.technician_stock_levels where org_id = v_org and technician_id = v_tech1 and item_type = 'spare' and item_id = v_spare3;
  perform pg_temp.chk('spare3: use #1 covered by the van, van balance now 2', v_rows = 2, v_rows::text);

  -- use #2: qty=4, van only has 2 left -> insufficient, falls to the warehouse/shortfall
  -- branch (van unchanged at 2, warehouse decremented by 4).
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ ticket spare3b') returning id into v_tk3b;
  insert into public.service_visits (org_id, ticket_id, technician_id) values (v_org, v_tk3b, v_tech1) returning id into v_visit3b;
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(
    v_org, v_visit3b, 0, 0, jsonb_build_array(jsonb_build_object('spare_id', v_spare3, 'qty', 4)),
    'cash'::payment_method, null, null, true
  );
  perform pg_temp.as_pg();
  perform pg_temp.chk('spare3: use #2 (qty=4) falls to the shortfall branch (van insufficient)',
    exists (select 1 from public.inventory_movements where org_id = v_org and item_id = v_spare3 and technician_id = v_tech1 and reason = 'service_use_shortfall' and change_qty = -4));
  select stock_qty into v_rows from public.technician_stock_levels where org_id = v_org and technician_id = v_tech1 and item_type = 'spare' and item_id = v_spare3;
  perform pg_temp.chk('spare3: van balance untouched by the shortfall branch, still 2', v_rows = 2, v_rows::text);

  -- return: qty=2, van has exactly 2 -> covers it (van 2 -> 0, warehouse +2).
  perform pg_temp.as_user(v_ops);
  v_return3_id := public.create_spare_return(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare3, 'qty_returned', 2)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('spare3: return of 2 recorded', v_return3_id is not null);

  -- the ledger aggregates the whole cycle: handed over 5, used 7 (3 via van + 4 via
  -- shortfall), returned 2, balance 0.
  perform pg_temp.as_user(v_ops);
  select qty_handed_over, qty_used, qty_returned, balance
    into v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance
    from public.technician_spare_ledger where org_id = v_org and technician_id = v_tech1 and spare_id = v_spare3;
  perform pg_temp.as_pg();
  perform pg_temp.chk('ledger: spare3 full cycle -- handed=5, used=7 (3 van + 4 shortfall), returned=2, balance=0',
    v_ledger_handed = 5 and v_ledger_used = 7 and v_ledger_returned = 2 and v_ledger_balance = 0,
    format('handed=%s used=%s returned=%s balance=%s', v_ledger_handed, v_ledger_used, v_ledger_returned, v_ledger_balance));

  -- technician_stock_levels agrees with the ledger's own balance column directly.
  select stock_qty into v_rows from public.technician_stock_levels where org_id = v_org and technician_id = v_tech1 and item_type = 'spare' and item_id = v_spare3;
  perform pg_temp.chk('spare3: technician_stock_levels.stock_qty matches the ledger balance of 0', v_rows = 0, v_rows::text);

  -- ── grants: no anon/public access to the new objects ──────────────────────────────────
  perform pg_temp.chk('anon has no EXECUTE on report_spare_handover_discrepancy',
    not has_function_privilege('anon', 'public.report_spare_handover_discrepancy(uuid,uuid,integer,text)', 'execute'));
  perform pg_temp.chk('authenticated has EXECUTE on report_spare_handover_discrepancy',
    has_function_privilege('authenticated', 'public.report_spare_handover_discrepancy(uuid,uuid,integer,text)', 'execute'));
  perform pg_temp.chk('anon has no SELECT on technician_spare_ledger',
    not has_table_privilege('anon', 'public.technician_spare_ledger', 'select'));
  perform pg_temp.chk('authenticated has SELECT on technician_spare_ledger',
    has_table_privilege('authenticated', 'public.technician_spare_ledger', 'select'));

  -- ── real-org data is untouched ─────────────────────────────────────────────────────────
  select md5(coalesce(string_agg(id::text || coalesce(given_by::text,'') , ',' order by id), '')) into fp_handovers_after
    from public.spare_handovers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into fp_notif_after from public.notifications
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real spare_handovers rows unchanged', fp_handovers_before = fp_handovers_after);
  perform pg_temp.chk('real notifications count unchanged', fp_notif_before = fp_notif_after, format('%s -> %s', fp_notif_before, fp_notif_after));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$CHAIN_TEST2$;

  v_newtest_text := $CHAIN_NEWTEST$-- Chained rehearsal test: proves the TRUE apply order (20261113100000 then 20261114100000)
-- leaves technician-facing spare hand-over flows working end to end, and the RLS hole closed.
-- Run only as part of the 20261114100000 rehearsal wrapper's chained rehearsal, AFTER both
-- migrations and both of their own test files have already executed in the same session.
-- Throwaway __TEST_ org only. NOT run against any database by this agent -- this file has
-- never been executed.
--
-- Covers the 2026-10-27 review's item 2(a)-(d):
--   (a) report_spare_handover_discrepancy (the technician dispute/report RPC) still works.
--   (b) confirm_spare_handover still works for the owning technician.
--   (c) the technician app's offline-sync queue calls the SAME RPC as (b) for a hand-over
--       acknowledgement -- see src/lib/offline/sync.ts, case 'spare_handover.confirm':
--       supabase.rpc('confirm_spare_handover', { p_handover_id, p_tech_sign_url,
--       p_admin_sign_url }). There is no separate "offline ack" RPC; the offline queue replays
--       the exact same call confirm_spare_handover's own online path makes (and its sibling
--       case 'spare_handover.report_discrepancy' replays report_spare_handover_discrepancy
--       verbatim -- (a) above already covers that one). So (b) and (c) are, by construction,
--       the same assertion against the same RPC; this file still records it as its own
--       numbered check per the review's wording, rather than silently folding it into (b).
--   (d) a technician's direct INSERT into spare_handovers is still refused with SQLSTATE
--       42501 -- re-confirmed here after BOTH migrations are chained, not just after
--       20261113100000 alone (20261114100000 does not touch RLS on spare_handovers, but this
--       re-proves it rather than assuming so).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_ops uuid; v_tp1 uuid; v_tech1 uuid;
  v_cust uuid; v_spare1 uuid; v_handover_id uuid; v_item1_id uuid;
  v_status text; v_tech_sign text; v_received_qty integer; v_notif_count integer;
begin
  insert into public.organizations (name) values ('__TEST_spare_handover_chain') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000003') returning id into v_cust;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ Spare Chain', 'T-SPC1', 75) returning id into v_spare1;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_spare1, 10, 'warehouse');

  perform pg_temp.as_user(v_ops);
  v_handover_id := public.create_spare_handover(v_org, v_tech1, current_date, jsonb_build_array(jsonb_build_object('spare_id', v_spare1, 'qty_given', 4)));
  perform pg_temp.as_pg();
  select id into v_item1_id from public.spare_handover_items where handover_id = v_handover_id and spare_id = v_spare1;
  perform pg_temp.chk('chain: hand-over created after both migrations applied in order', v_handover_id is not null and v_item1_id is not null);

  -- (d) direct technician INSERT is still refused -- re-confirmed after BOTH migrations.
  perform pg_temp.as_user(v_tp1);
  begin
    insert into public.spare_handovers (org_id, technician_id, date, status) values (v_org, v_tech1, current_date, 'pending');
    perform pg_temp.chk('chain (d): technician direct INSERT into spare_handovers still refused (42501) after both migrations', false);
  exception when sqlstate '42501' then
    perform pg_temp.chk('chain (d): technician direct INSERT into spare_handovers still refused (42501) after both migrations', true, sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- (a) report_spare_handover_discrepancy (dispute/report path) still works for a technician.
  perform pg_temp.as_user(v_tp1);
  perform public.report_spare_handover_discrepancy(v_org, v_item1_id, 2, '__TEST_ chain dispute');
  perform pg_temp.as_pg();
  select received_qty into v_received_qty from public.spare_handover_items where id = v_item1_id;
  perform pg_temp.chk('chain (a): report_spare_handover_discrepancy still works for a technician', v_received_qty = 2, v_received_qty::text);
  select count(*) into v_notif_count from public.notifications
    where org_id = v_org and role = 'operation_admin' and type = 'spare_handover_disputed' and ref_id = v_handover_id;
  perform pg_temp.chk('chain (a): staff is still notified of the dispute', v_notif_count = 1, v_notif_count::text);

  -- (b)/(c) confirm_spare_handover -- the exact RPC the offline-sync queue's
  -- 'spare_handover.confirm' case calls (src/lib/offline/sync.ts) -- still works for the
  -- owning technician.
  perform pg_temp.as_user(v_tp1);
  perform public.confirm_spare_handover(v_handover_id, 'data:image/png;base64,__TEST_chain_tech_sig', 'data:image/png;base64,__TEST_chain_admin_sig');
  perform pg_temp.as_pg();
  select status, tech_sign_url into v_status, v_tech_sign from public.spare_handovers where id = v_handover_id;
  perform pg_temp.chk('chain (b)/(c): confirm_spare_handover (offline-sync''s hand-over-ack RPC) still works for the owning technician', v_status = 'confirmed' and v_tech_sign is not null, coalesce(v_status, '<null>'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$CHAIN_NEWTEST$;

  v_orig_confirm_pgtemp := $CHAIN_OCONFIRM$create or replace function pg_temp.confirm_spare_handover(
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
$CHAIN_OCONFIRM$;

  v_orig_create_pgtemp := $CHAIN_OCREATE$create or replace function pg_temp.create_spare_handover(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_given}, ...]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_handover_id uuid;
  v_item record;
  v_new_stock integer;
  v_have integer;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_handover: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_handover: caller is not ops staff';
  end if;

  insert into public.spare_handovers (org_id, technician_id, date, status)
  values (p_org_id, p_technician_id, p_date, 'pending')
  on conflict do nothing
  returning id into v_handover_id;

  if v_handover_id is null then
    insert into public.spare_handovers (org_id, technician_id, date, status)
    values (p_org_id, p_technician_id, p_date, 'pending')
    returning id into v_handover_id;
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_given integer)
    loop
      if v_item.qty_given is null or v_item.qty_given <= 0 then
        continue;
      end if;
      insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (p_org_id, v_handover_id, v_item.spare_id, v_item.qty_given);

      -- Warehouse-side decrement — unchanged conditional UPDATE.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty_given
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'warehouse' and stock_qty >= v_item.qty_given
        returning stock_qty into v_new_stock;

      if v_new_stock is null then
        select stock_qty into v_have
          from public.inventory
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse';
        raise exception 'create_spare_handover: insufficient warehouse stock for spare % (need %, have %)',
          v_item.spare_id, v_item.qty_given, coalesce(v_have, 0);
      end if;

      -- Per-technician van-side increment — was a pooled `inventory`
      -- location='van' upsert, now this technician's own ledger row.
      insert into public.technician_stock_levels (org_id, technician_id, item_type, item_id, stock_qty)
      values (p_org_id, p_technician_id, 'spare', v_item.spare_id, v_item.qty_given)
      on conflict (org_id, technician_id, item_type, item_id)
      do update set stock_qty = technician_stock_levels.stock_qty + excluded.stock_qty, updated_at = now();

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty_given, 'spare_handover', v_handover_id, p_technician_id);
    end loop;
  end if;

  return v_handover_id;
end;
$$;
$CHAIN_OCREATE$;

  v_orig_csi_pgtemp := $CHAIN_OCSI$create or replace function pg_temp.create_service_invoice(p_org_id uuid, p_visit_id uuid, p_service_charge numeric, p_discount_percent numeric, p_spares jsonb, p_payment_method payment_method, p_txn_id text, p_payment_description text, p_is_chargeable boolean, p_amount_paid numeric default null::numeric, p_installations jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_movement_reason text;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
  v_rental_contract rental_contracts;
  v_rental_plan rental_plans;
  v_rental_interval_months integer;
  v_rental_visit_date date;
  v_rental_ticket_id uuid;
  v_rental_address_id uuid;
  v_install record; -- INSTALLATION TRACKING
  v_credit_qty integer;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'create_service_invoice: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_service_invoice: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null then
    raise exception 'create_service_invoice: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'create_service_invoice: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket is null then
    raise exception 'create_service_invoice: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_service_invoice: no settings row for org %', p_org_id;
  end if;

  -- A completed ticket is never invoiced (or credited) twice. The same technician repeating the call (offline-queue replay)
  -- gets the existing invoice back and nothing else is written; anyone else gets an error.
  if v_ticket.status = 'completed' then
    if v_ticket.invoice_id is not null and v_visit.technician_id = v_tech_id then
      return jsonb_build_object('invoice_id', v_ticket.invoice_id,
        'total', (select i.total from public.invoices i where i.id = v_ticket.invoice_id),
        'approval_id', null, 'already_completed', true);
    end if;
    raise exception 'create_service_invoice: ticket % is already completed', v_ticket.id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      if v_item.qty is null or v_item.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for spare %', v_item.spare_id;
      end if;
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      if v_price is null then
        raise exception 'create_service_invoice: spare % not found in org %', v_item.spare_id, p_org_id;
      end if;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      if p_is_chargeable or not v_is_spare_covered then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid
  ) returning * into v_invoice;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      -- This technician's own van balance first (was the pooled, org-wide
      -- `inventory` location='van' row - see this migration's header).
      update public.technician_stock_levels
        set stock_qty = stock_qty - v_item.qty, updated_at = now()
        where org_id = p_org_id and technician_id = v_tech_id
          and item_type = 'spare' and item_id = v_item.spare_id and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;

      if v_new_stock is not null then
        v_movement_reason := 'service_use_van';
      else
        -- Van didn't cover it (never handed over, or not enough) - fall
        -- back to warehouse, same conditional UPDATE as before, but now
        -- tagged so Group 5 reporting can flag the shortfall distinctly
        -- from a normal van deduction.
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
        v_movement_reason := 'service_use_shortfall';
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, v_movement_reason, p_visit_id, v_tech_id);
    end loop;
  end if;

  -- INSTALLATION TRACKING: distinct from spares - logs which products were
  -- newly installed on this visit, purely for incentive counting (no
  -- invoice line, no stock movement - the product itself was already sold/
  -- stocked through its own path; this just credits the technician).
  if p_installations is not null and jsonb_array_length(p_installations) > 0 then
    for v_install in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
    loop
      if v_install.qty is null or v_install.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for installed product %', v_install.product_id;
      end if;
      if not exists (select 1 from public.products where id = v_install.product_id and org_id = p_org_id) then
        raise exception 'create_service_invoice: product % not found in org %', v_install.product_id, p_org_id;
      end if;

      insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty)
      values (p_org_id, p_visit_id, v_tech_id, v_install.product_id, v_install.qty);
    end loop;
  end if;

  -- Installation incentive: the ticket's per-unit charge (a master-editable snapshot) x units logged for the ticket's
  -- product, minimum 1. Created PENDING; the master approves it before Compute counts it. One credit per ticket+technician.
  if v_ticket.type = 'installation' and v_ticket.product_id is not null and coalesce(v_ticket.installation_charge_snapshot, 0) > 0 then
    select greatest(1, coalesce(sum(il.qty), 0))::integer into v_credit_qty
    from public.installations_logged il
    where il.visit_id = p_visit_id and il.product_id = v_ticket.product_id;
    insert into public.installation_incentive_credits (org_id, ticket_id, visit_id, technician_id, product_id, qty, unit_amount, amount, status)
    values (p_org_id, v_ticket.id, p_visit_id, v_tech_id, v_ticket.product_id, v_credit_qty,
            v_ticket.installation_charge_snapshot, v_ticket.installation_charge_snapshot * v_credit_qty, 'pending')
    on conflict (ticket_id, technician_id) do nothing;
    if found then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (p_org_id, 'master', 'installation_credit_pending', 'Installation incentive to approve',
              format('Installation completed: incentive of %s (%s unit(s)) is waiting for your approval.',
                     v_ticket.installation_charge_snapshot * v_credit_qty, v_credit_qty), v_ticket.id);
    end if;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    update public.amc_contracts
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if v_ticket.type = 'warranty' and v_ticket.warranty_id is not null then
    update public.warranties
      set next_service_date = (
        select min((a.scheduled_at at time zone 'Asia/Kolkata')::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.warranty_id = v_ticket.warranty_id
          and st.type = 'warranty'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.warranty_id;
  end if;

  if v_ticket.type = 'rental' and v_ticket.rental_contract_id is not null then
    select * into v_rental_contract from public.rental_contracts where id = v_ticket.rental_contract_id;
    if v_rental_contract.status = 'active' then
      select * into v_rental_plan from public.rental_plans where id = v_rental_contract.plan_id;
      -- next visit: round(12 / visits_per_year) months from today (was integer division), rolled to a working day
      v_rental_interval_months := greatest(1, public._visit_month_offset(v_rental_plan.visits_per_year, 1));
      v_rental_visit_date := public._visit_working_day(p_org_id, ((now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_rental_interval_months))::date);
      v_rental_address_id := coalesce(v_rental_contract.address_id, v_ticket.address_id);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, rental_contract_id
      ) values (
        p_org_id, v_rental_contract.customer_id, v_rental_address_id, v_rental_contract.product_id,
        'Rental scheduled service', v_rental_plan.name, 'rental', 'normal', 'open', 'walk_in', v_rental_contract.id
      )
      returning id into v_rental_ticket_id;

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
      values (p_org_id, v_rental_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_rental_visit_date),
              public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

      perform public._auto_assign_ticket_internal(v_rental_ticket_id, p_org_id, p_skip_rating_logic => true);

      update public.rental_contracts set next_service_date = v_rental_visit_date where id = v_rental_contract.id;
    end if;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if (now() at time zone 'Asia/Kolkata')::time >= v_settings.work_end then
    update public.attendance
    set shift_end_prompt_pending = true
    where technician_id = v_tech_id and org_id = p_org_id
      and date = (now() at time zone 'Asia/Kolkata')::date;

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select p_org_id, p.id, 'shift_end_prompt', 'Shift end reached',
      format('Your shift ended at %s. Reply to continue or check out.', to_char(v_settings.work_end, 'HH12:MI AM')), v_invoice.id
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  else
    perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$function$;
$CHAIN_OCSI$;

  -- ── 3. sha256 pins on the five embedded files ───────────────────────────────────────────
  -- CR-tolerance: hashed and executed via replace(..., E'\r', '') so a CRLF-saved copy of this
  -- same file still hashes and executes identically to the LF original. The pinned sha256
  -- constants themselves are unchanged (still the LF hashes).
  if encode(sha256(convert_to(replace(v_mig1_text, E'\r', ''), 'UTF8')), 'hex') <> v_mig1_sha256 then
    raise exception 'rehearsal refused: embedded 20261113100000 migration text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_mig1_sha256;
  end if;
  if encode(sha256(convert_to(replace(v_test1_text, E'\r', ''), 'UTF8')), 'hex') <> v_test1_sha256 then
    raise exception 'rehearsal refused: embedded 20261113100000 test text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_test1_sha256;
  end if;
  if encode(sha256(convert_to(replace(v_mig2_text, E'\r', ''), 'UTF8')), 'hex') <> v_mig2_sha256 then
    raise exception 'rehearsal refused: embedded 20261114100000 migration text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_mig2_sha256;
  end if;
  if encode(sha256(convert_to(replace(v_test2_text, E'\r', ''), 'UTF8')), 'hex') <> v_test2_sha256 then
    raise exception 'rehearsal refused: embedded 20261114100000 test text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_test2_sha256;
  end if;
  if encode(sha256(convert_to(replace(v_newtest_text, E'\r', ''), 'UTF8')), 'hex') <> v_newtest_sha256 then
    raise exception 'rehearsal refused: embedded chained post-migration test text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_newtest_sha256;
  end if;

  -- ── 4. live-md5 pre-check: all THREE functions this pair of migrations touches must still
  --      match their pinned ORIGINAL bodies before we dare redefine any of them. Recreate
  --      each pinned original in pg_temp, then compare md5(pg_get_functiondef(...)) of that
  --      pg_temp copy against the actually-live public function -- normalizing away the
  --      schema-qualified name first (the only part pg_get_functiondef would otherwise always
  --      disagree on between pg_temp.X and public.X even for byte-identical bodies). Done for
  --      all three BEFORE either migration is applied -- nothing is redefined blindly.
  --      Postgres renders a session's real temporary schema as pg_temp_N (e.g. pg_temp_3) in
  --      pg_get_functiondef's output -- never literally "pg_temp", even though "pg_temp" is a
  --      valid resolving alias when used in a type cast like
  --      'pg_temp.confirm_spare_handover(...)'::regprocedure. Each pattern below matches both
  --      the bare alias form and the real pg_temp_N form it will actually see. Known, accepted
  --      limitation of this whole comparison mechanism: pg_get_functiondef's output never
  --      includes the function owner or any COMMENT ON FUNCTION text, so even after this fix
  --      it cannot catch an owner change or a comment-only edit to the live function -- it only
  --      catches a change to the function's actual signature, language, security,
  --      search_path, volatility, or body. That is accepted, not something to guard against
  --      further here.
  execute replace(v_orig_confirm_pgtemp, E'\r', '');
  execute replace(v_orig_create_pgtemp, E'\r', '');
  execute replace(v_orig_csi_pgtemp, E'\r', '');

  v_pgtemp_def := regexp_replace(
    pg_get_functiondef('pg_temp.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'pg_temp(_[0-9]+)?\.confirm_spare_handover', 'FN', 'g');
  v_live_def := regexp_replace(
    pg_get_functiondef('public.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'public\.confirm_spare_handover', 'FN', 'g');
  if md5(v_pgtemp_def) <> md5(v_live_def) then
    raise exception 'rehearsal refused: live confirm_spare_handover no longer matches the pinned ORIGINAL body (someone changed it since this migration pair was written) -- refusing to redefine it blindly. Resolve the drift and re-pin before rehearsing again.';
  end if;

  v_pgtemp_def := regexp_replace(
    pg_get_functiondef('pg_temp.create_spare_handover(uuid,uuid,date,jsonb)'::regprocedure),
    'pg_temp(_[0-9]+)?\.create_spare_handover', 'FN', 'g');
  v_live_def := regexp_replace(
    pg_get_functiondef('public.create_spare_handover(uuid,uuid,date,jsonb)'::regprocedure),
    'public\.create_spare_handover', 'FN', 'g');
  if md5(v_pgtemp_def) <> md5(v_live_def) then
    raise exception 'rehearsal refused: live create_spare_handover no longer matches the pinned ORIGINAL body (someone changed it since this migration pair was written) -- refusing to redefine it blindly. Resolve the drift and re-pin before rehearsing again.';
  end if;

  v_pgtemp_def := regexp_replace(
    pg_get_functiondef('pg_temp.create_service_invoice(uuid,uuid,numeric,numeric,jsonb,payment_method,text,text,boolean,numeric,jsonb)'::regprocedure),
    'pg_temp(_[0-9]+)?\.create_service_invoice', 'FN', 'g');
  v_live_def := regexp_replace(
    pg_get_functiondef('public.create_service_invoice(uuid,uuid,numeric,numeric,jsonb,payment_method,text,text,boolean,numeric,jsonb)'::regprocedure),
    'public\.create_service_invoice', 'FN', 'g');
  if md5(v_pgtemp_def) <> md5(v_live_def) then
    raise exception 'rehearsal refused: live create_service_invoice no longer matches the pinned ORIGINAL body (someone changed it since this migration pair was written) -- refusing to redefine it blindly. Resolve the drift and re-pin before rehearsing again.';
  end if;

  -- ── 5. relative fingerprint of the real organisation, BEFORE either migration runs ─────
  --      Columns used in the checksum are deliberately limited to id/technician_id/status --
  --      every one of them exists on spare_handovers today, BEFORE 20261114100000 adds
  --      given_by. See header note.
  select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'inventory_movements', (select count(*) from public.inventory_movements m join public.organizations o on o.id = m.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || coalesce(h.technician_id::text, '') || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) into v_fp_before;

  -- ── 6. rehearse migration 1 + its test (both inside this one implicit transaction) ──────
  begin
    execute replace(v_mig1_text, E'\r', '');
  exception when sqlstate '55P03' then
    v_lock_timeout_hit := true;
    raise exception 'rehearsal refused: lock_timeout (5s) exceeded while applying 20261113100000 (DROP/CREATE POLICY or CREATE OR REPLACE FUNCTION blocked by a concurrent transaction) -- this is a LOCK CONTENTION failure, not a migration logic failure; retry when the table/function is not under contention';
  end;
  begin
    execute replace(v_test1_text, E'\r', '');
    v_test1_results := '(test completed without raising -- unexpected: the test file always ends in its own RAISE EXCEPTION ''RESULTS...''; treat this as a WRONG ERROR condition, not a pass)';
  exception
    when sqlstate '55P03' then
      v_lock_timeout_hit := true;
      v_test1_results := 'LOCK CONTENTION: lock_timeout (5s) exceeded while running test 1 -- not a logic failure, retry when not under contention';
    when others then
      v_test1_results := sqlerrm;
  end;

  -- ── 7. rehearse migration 2 + its test, on top of migration 1's now-applied state ───────
  begin
    execute replace(v_mig2_text, E'\r', '');
  exception when sqlstate '55P03' then
    v_lock_timeout_hit := true;
    raise exception 'rehearsal refused: lock_timeout (5s) exceeded while applying 20261114100000 -- this is a LOCK CONTENTION failure, not a migration logic failure; retry when the table/function is not under contention';
  end;
  begin
    execute replace(v_test2_text, E'\r', '');
    v_test2_results := '(test completed without raising -- unexpected: the test file always ends in its own RAISE EXCEPTION ''RESULTS...''; treat this as a WRONG ERROR condition, not a pass)';
  exception
    when sqlstate '55P03' then
      v_lock_timeout_hit := true;
      v_test2_results := 'LOCK CONTENTION: lock_timeout (5s) exceeded while running test 2 -- not a logic failure, retry when not under contention';
    when others then
      v_test2_results := sqlerrm;
  end;

  -- ── 8. new chained test: proves the technician-facing RPCs and the closed RLS hole still
  --      work with BOTH migrations live together, not just each one alone ──────────────────
  begin
    execute replace(v_newtest_text, E'\r', '');
    v_newtest_results := '(test completed without raising -- unexpected: the test file always ends in its own RAISE EXCEPTION ''RESULTS...''; treat this as a WRONG ERROR condition, not a pass)';
  exception
    when sqlstate '55P03' then
      v_lock_timeout_hit := true;
      v_newtest_results := 'LOCK CONTENTION: lock_timeout (5s) exceeded while running the chained post-migration test -- not a logic failure, retry when not under contention';
    when others then
      v_newtest_results := sqlerrm;
  end;

  -- ── 9. relative fingerprint, AFTER both migrations + all three tests ────────────────────
  --      Same column set as the BEFORE block (id/technician_id/status) -- kept byte-identical
  --      in shape to step 5 except for the timing, per the fingerprint-bug fix.
  select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'inventory_movements', (select count(*) from public.inventory_movements m join public.organizations o on o.id = m.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || coalesce(h.technician_id::text, '') || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) into v_fp_after;

  -- ── 10. unconditional final RAISE -- this is what rolls everything back. Nothing in this
  --       file ever reaches a database commit.
  raise exception E'CHAINED REHEARSAL RESULTS (20261113100000 -> 20261114100000, true apply order)\nsha256 pins: migration 1 OK, test 1 OK, migration 2 OK, test 2 OK, chained test OK\nlive-md5 pre-check: confirm_spare_handover OK, create_spare_handover OK, create_service_invoice OK (all matched their pinned ORIGINAL live bodies)\nlock_timeout hit during rehearsal: %\nfingerprint before (real orgs only): %\nfingerprint after  (real orgs only): %\nfingerprint unchanged: %\n\n--- test 1 (20261113100000) ---\n%\n\n--- test 2 (20261114100000) ---\n%\n\n--- chained post-migration test ---\n%',
    v_lock_timeout_hit, v_fp_before, v_fp_after, (v_fp_before = v_fp_after),
    coalesce(v_test1_results, '(no test result captured)'),
    coalesce(v_test2_results, '(no test result captured)'),
    coalesce(v_newtest_results, '(no test result captured)');
end
$rehearsal$;
