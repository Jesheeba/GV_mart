-- Rehearsal wrapper for 20261113100000_close_spare_handover_technician_rls_hole.sql.
-- NOT run against any database by this agent. Intended usage: a reviewer with real DB access
-- runs this file after 18:00 IST; it refuses before that, refuses if the lock it needs isn't
-- available within 5 seconds (reported distinctly, not folded into a generic failure), refuses
-- if either embedded file (migration, test) no longer matches its pinned sha256 (re-pin after
-- any edit to either file), refuses if the live confirm_spare_handover no longer matches its
-- pinned ORIGINAL body (someone else changed it since this migration was written -- never
-- trust a pinned text blindly), otherwise rehearses the migration plus its test inside ONE DO
-- block with no top-level BEGIN/COMMIT/SAVEPOINT/ROLLBACK, takes a relative fingerprint of the
-- real organisation (row counts across every spare/technician-stock table, scoped to
-- non-__TEST_ orgs, plus a checksum) both before and after, and ends in an unconditional RAISE
-- so nothing here ever persists -- the migration's policy/function changes and the test's
-- __TEST_ rows are both rolled back by that final raise.
--
-- The migration and test are embedded as literal text and run via EXECUTE (SPI_execute
-- accepts a multi-statement string) -- this file never concatenates the two into one file on
-- disk; they are embedded separately here only for the rehearsal to run them in sequence.
--
-- All three pins below use encode(sha256(convert_to(text,'UTF8')),'hex') -- the migration
-- text, the test text, and (after normalizing away the schema-qualified function name, the
-- only part pg_get_functiondef would otherwise always disagree on between a pg_temp copy and
-- the real public.confirm_spare_handover even for byte-identical bodies) the ORIGINAL
-- confirm_spare_handover definition. This upgrades the sibling 20261114100000 wrapper's
-- md5-based live-definition pre-check to sha256 throughout, per this migration's own
-- requirements -- the two mechanisms are equivalent in purpose (detect drift before blindly
-- redefining something), only the hash function differs.
do $rehearsal$
declare
  v_now_ist time;
  v_migration_sha256 text := 'd582f42cd850986a7374333c60706d41973295deac5c710de9ad75dbc2b63778';
  v_test_sha256 text := '8ff8b144a0c77819066cc023ed151d5d14bca7955d7366153322fb7b14f7c5f3';
  v_migration_text text;
  v_test_text text;
  v_orig_csh_pgtemp text;
  v_org_fp text;
  v_live_csh_def text;
  v_pgtemp_csh_def text;
  v_fp_before jsonb;
  v_fp_after jsonb;
  v_test_results text;
  v_lock_timeout_hit boolean := false;
begin
  -- ── 0. lock budget -- first executed statement, before even the time gate, so a real run
  --      can never hang on a lock. This rehearsal touches spare_handovers / spare_handover_items
  --      (DROP/CREATE POLICY needs an ACCESS EXCLUSIVE-ish lock briefly) and the
  --      confirm_spare_handover function.
  set local lock_timeout = '5s';

  -- ── 1. time gate ──────────────────────────────────────────────────────────────────────
  v_now_ist := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  if v_now_ist < time '18:00' then
    raise exception 'rehearsal refused: run only after 18:00 IST (Asia/Kolkata) -- current IST time is %', v_now_ist;
  end if;

  -- ── 2. organisation fingerprint pin -- the very first check after the lock budget and
  --      time gate, before anything else including the sha256 file pins below. This literal
  --      value was supplied by the reviewer who has real DB access; this rehearsal cannot and
  --      does not attempt to verify or second-guess it -- it is wired in exactly as given.
  select md5(o.id::text || '|' || o.name) into v_org_fp
    from public.organizations o
    where o.name not like '\_\_TEST\_%' escape '\'
    order by o.created_at asc, o.id asc
    limit 1;
  if v_org_fp is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- ── 3. embedded text ──────────────────────────────────────────────────────────────────
  v_migration_text := $MIG_TEXT$
-- Close the direct-write hole in spare_handovers / spare_handover_items (2026-10-27 review).
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
$MIG_TEXT$;

  v_test_text := $TEST_TEXT$
-- Rolled-back DB tests for 20261113100000_close_spare_handover_technician_rls_hole.sql.
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
$TEST_TEXT$;

  v_orig_csh_pgtemp := $OCSH_TEXT$
create or replace function pg_temp.confirm_spare_handover(
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

  -- ── 4. sha256 pins on the embedded files ────────────────────────────────────────────────
  -- CR-tolerance: hashed and executed via replace(..., E'\r', '') so a CRLF-saved copy of this
  -- same file still hashes and executes identically to the LF original. The pinned sha256
  -- constants themselves are unchanged (still the LF hashes).
  if encode(sha256(convert_to(replace(v_migration_text, E'\r', ''), 'UTF8')), 'hex') <> v_migration_sha256 then
    raise exception 'rehearsal refused: embedded migration text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_migration_sha256;
  end if;
  if encode(sha256(convert_to(replace(v_test_text, E'\r', ''), 'UTF8')), 'hex') <> v_test_sha256 then
    raise exception 'rehearsal refused: embedded test text does not match its pinned sha256 (% expected) -- re-pin after any edit', v_test_sha256;
  end if;

  -- ── 5. sha256 pre-check: the live confirm_spare_handover must still match the pinned
  --      ORIGINAL (security invoker, no search_path) before we dare redefine it. Recreate the
  --      pinned original in pg_temp, then compare encode(sha256(convert_to(
  --      pg_get_functiondef(...),'UTF8')),'hex') of that pg_temp copy against the actually-live
  --      public function -- normalizing away the schema-qualified name first (the only part
  --      pg_get_functiondef would otherwise always disagree on between pg_temp.X and public.X
  --      even for byte-identical bodies). Wrapped so a lock-timeout here is reported distinctly
  --      from a genuine drift failure.
  begin
    execute replace(v_orig_csh_pgtemp, E'\r', '');
  exception when sqlstate '55P03' then
    v_lock_timeout_hit := true;
    raise exception 'rehearsal refused: lock_timeout (5s) exceeded while preparing the pinned-original comparison for confirm_spare_handover -- this is a LOCK CONTENTION failure, not a logic or drift failure; retry when the table/function is not under contention';
  end;

  -- Postgres renders a session's real temporary schema as pg_temp_N (e.g. pg_temp_3) in
  -- pg_get_functiondef's output -- never literally "pg_temp", even though "pg_temp" is a
  -- valid resolving alias when used in a type cast like 'pg_temp.confirm_spare_handover(...)'
  -- ::regprocedure. The pattern below matches both the bare alias form and the real pg_temp_N
  -- form it will actually see. Known, accepted limitation of this whole comparison mechanism:
  -- pg_get_functiondef's output never includes the function owner or any COMMENT ON FUNCTION
  -- text, so even after this fix it cannot catch an owner change or a comment-only edit to the
  -- live function -- it only catches a change to the function's actual signature, language,
  -- security, search_path, volatility, or body. That is accepted, not something to guard
  -- against further here.
  v_pgtemp_csh_def := regexp_replace(
    pg_get_functiondef('pg_temp.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'pg_temp(_[0-9]+)?\.confirm_spare_handover', 'FN', 'g');
  v_live_csh_def := regexp_replace(
    pg_get_functiondef('public.confirm_spare_handover(uuid,text,text)'::regprocedure),
    'public\.confirm_spare_handover', 'FN', 'g');
  if encode(sha256(convert_to(v_pgtemp_csh_def, 'UTF8')), 'hex') <> encode(sha256(convert_to(v_live_csh_def, 'UTF8')), 'hex') then
    raise exception 'rehearsal refused: live confirm_spare_handover no longer matches the pinned ORIGINAL body (someone changed it since this migration was written) -- refusing to redefine it blindly. Resolve the drift and re-pin before rehearsing again.';
  end if;

  -- ── 6. relative fingerprint of the real organisation, BEFORE ──────────────────────────
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

  -- ── 7. rehearse: apply the migration, then run its test (both inside this one implicit
  --      transaction -- nothing here is ever committed; the final raise below undoes it all).
  --      Wrapped so a lock-timeout mid-apply is reported distinctly from a test/logic failure.
  begin
    execute replace(v_migration_text, E'\r', '');
  exception when sqlstate '55P03' then
    v_lock_timeout_hit := true;
    raise exception 'rehearsal refused: lock_timeout (5s) exceeded while applying the migration (DROP/CREATE POLICY or CREATE OR REPLACE FUNCTION blocked by a concurrent transaction) -- this is a LOCK CONTENTION failure, not a migration logic failure; retry when the table/function is not under contention';
  end;

  begin
    execute replace(v_test_text, E'\r', '');
    v_test_results := '(test completed without raising -- unexpected: the test file always ends in its own RAISE EXCEPTION ''RESULTS...''; treat this as a WRONG ERROR condition, not a pass)';
  exception
    when sqlstate '55P03' then
      v_lock_timeout_hit := true;
      v_test_results := 'LOCK CONTENTION: lock_timeout (5s) exceeded while running the test -- not a logic failure, retry when not under contention';
    when others then
      v_test_results := sqlerrm;
  end;

  -- ── 8. relative fingerprint, AFTER ──────────────────────────────────────────────────────
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

  -- ── 9. unconditional final RAISE -- this is what rolls everything back. Nothing in this
  --      file ever reaches a database commit.
  raise exception E'REHEARSAL RESULTS (20261113100000_close_spare_handover_technician_rls_hole)\nsha256 pins: migration OK, test OK\nsha256 pre-check: confirm_spare_handover OK (matched its pinned ORIGINAL live body)\nlock_timeout hit during rehearsal: %\nfingerprint before (real orgs only): %\nfingerprint after  (real orgs only): %\nfingerprint unchanged: %\n\n%',
    v_lock_timeout_hit, v_fp_before, v_fp_after, (v_fp_before = v_fp_after), coalesce(v_test_results, '(no test result captured)');
end
$rehearsal$;
