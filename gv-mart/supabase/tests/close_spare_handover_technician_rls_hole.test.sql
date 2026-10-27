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
  perform pg_temp.chk('confirm_spare_handover is now security definer',
    (select prosecdef from pg_proc where proname = 'confirm_spare_handover'));
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
