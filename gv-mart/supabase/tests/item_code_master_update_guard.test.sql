-- Rolled-back DB tests for 20261104120000_item_code_master_update_guard (P4 part 3).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies all three P4 migrations and
-- then this file in ONE request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway
-- __TEST_ organisation only.
--
-- RLS note read before the G-block below: products_write_master already restricts the WHOLE products row to
-- master (is_master() in USING and WITH CHECK). Under today's policies, operation_admin/sales_admin's own UPDATE
-- never reaches this trigger at all — RLS's USING clause makes the row invisible for UPDATE, so the statement
-- succeeds with 0 rows affected, not an exception (see R-block). To prove the TRIGGER itself (not RLS) refuses a
-- non-master change — the thing that actually matters if products_write_master is ever loosened later — the
-- G-block below temporarily disables row level security on products, inside this same rolled-back transaction,
-- so the row is reachable and only the trigger is left standing. RLS is re-enabled immediately after. Nothing here
-- is ever committed regardless (the whole file still ends in an unconditional RAISE).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
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
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;

do $t$
declare
  v_org uuid; m uuid; o uuid; s uuid; v_brand uuid; v_model uuid; v_product uuid; x text; v_code text;
  v_proc record;
begin
  -- F: the function itself is SECURITY INVOKER with a pinned search_path, as specified (not SECURITY DEFINER).
  select p.prosecdef, p.proconfig into v_proc
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'guard_item_code_update';
  perform pg_temp.chk('F1 guard_item_code_update is SECURITY INVOKER (prosecdef = false)', v_proc.prosecdef = false, v_proc.prosecdef::text);
  perform pg_temp.chk('F2 guard_item_code_update has search_path pinned to public',
    v_proc.proconfig is not null and 'search_path=public' = any(v_proc.proconfig), coalesce(v_proc.proconfig::text, 'null'));
  perform pg_temp.chk('F3 neither anon nor authenticated holds EXECUTE on guard_item_code_update() (explicit revoke; belt-and-suspenders on top of it being un-callable outside trigger context anyway)',
    not has_function_privilege('anon', 'public.guard_item_code_update()', 'execute')
    and not has_function_privilege('authenticated', 'public.guard_item_code_update()', 'execute'));

  -- T: the trigger is BEFORE UPDATE OF item_code specifically, not a blanket BEFORE UPDATE.
  -- (review fix: compared via the TEXT form of tgattr/attnum, not tgattr::int2[] = array_agg(...)::int2[] --
  -- int2vector::int2[] keeps a zero-based lower bound while array_agg(...)::int2[] is one-based, and Postgres
  -- array equality compares bounds too, so the array-form comparison was false even for a correctly-scoped
  -- trigger. tgattr is a vector of the column numbers the trigger is scoped to; this trigger is scoped to one
  -- column, so comparing its text form to that one column's attnum, as text, is exact for this trigger's shape.)
  perform pg_temp.chk('T1 guard_item_code_update trigger exists on products, fires only when item_code is in the UPDATE''s column list',
    exists (
      select 1 from pg_trigger tg
      join pg_attribute a on a.attrelid = tg.tgrelid and a.attname = 'item_code'
      where tg.tgrelid = 'public.products'::regclass and tg.tgname = 'guard_item_code_update'
        and tg.tgattr::text = a.attnum::text));

  insert into public.organizations(name) values ('__TEST_p4c') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org); s := pg_temp.mkuser('sales_admin', v_org);
  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;
  insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (v_org, v_brand, v_model, '__TEST_product', 'ro', 1000, 'RO-STD-01') returning id into v_product;

  -- W: master, unaffected by this migration — can still change item_code, and every other column stays editable.
  x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-02'' where id = %L', v_product));
  perform pg_temp.chk('W1 master can still change item_code (the guard allows master through)', x = 'ok:1', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('W1b the value round-trips', v_code = 'RO-STD-02', coalesce(v_code, 'null'));
  x := pg_temp.act(m, format('update public.products set price = 1234 where id = %L', v_product));
  perform pg_temp.chk('W2 master can still change a column OTHER than item_code (the guard only fires on item_code, never blocked a thing here)', x = 'ok:1', x);
  x := pg_temp.act(m, format('update public.products set name = ''__TEST_product'', item_code = ''RO-STD-02'' where id = %L', v_product));
  perform pg_temp.chk('W3 re-sending the SAME item_code value in an UPDATE''s SET list is a no-op for the guard (IS DISTINCT FROM), and still succeeds', x = 'ok:1', x);

  -- R: today, before this trigger is even reached, products_write_master''s RLS already makes the row invisible
  -- to a non-master UPDATE — the statement succeeds with 0 rows affected, not an exception. This is EXISTING
  -- behaviour (product_item_code.test.sql''s W2/W3), restated here only to set up the contrast with the G-block.
  x := pg_temp.act(o, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('R1 operation_admin''s UPDATE affects 0 rows under normal RLS (RLS, not this trigger, is what blocks it today)', x = 'ok:0', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('R2 the value is unchanged by R1', v_code = 'RO-STD-02', coalesce(v_code, 'null'));

  -- G: isolate the TRIGGER itself from RLS, so a non-master write actually reaches it. This is the guard this
  -- migration adds; it must raise on its own, independent of whatever products_write_master does or will do.
  alter table public.products disable row level security;
  x := pg_temp.act(o, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('G1 with RLS OUT OF THE WAY, operation_admin''s item_code change is refused by the TRIGGER itself', x like 'err:%Only master can change%', x);
  x := pg_temp.act(s, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('G2 same for sales_admin', x like 'err:%Only master can change%', x);
  x := pg_temp.act(o, format('update public.products set price = 999 where id = %L', v_product));
  perform pg_temp.chk('G3 ...but operation_admin can still change a column OTHER than item_code once RLS is out of the way (the guard is scoped to item_code only)', x = 'ok:1', x);
  x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-03'' where id = %L', v_product));
  perform pg_temp.chk('G4 master still succeeds with RLS disabled too (is_master() does not depend on RLS)', x = 'ok:1', x);
  alter table public.products enable row level security;
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('G5 after re-enabling RLS, the value reflects only what master (G4) actually set', v_code = 'RO-STD-03', coalesce(v_code, 'null'));

  -- S0: explicitly reset the session's claims before S1 — the G-block above ran pg_temp.act calls that each set
  -- request.jwt.claims via set_config(..., true) (transaction-local), and 'reset role' only resets the ROLE, not
  -- that GUC. Clearing it here, and proving auth.uid() actually reads back null afterward, is what makes S1 below
  -- a genuine service-role/migration-write case rather than an accidental leftover claim from G4's master call.
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.chk('S0 request.jwt.claims is cleared and auth.uid() reads back null before the service-role/migration-write case below', auth.uid() is null, coalesce(auth.uid()::text, 'null'));

  -- S: service-role / migration writes (auth.uid() is null in this session — no request.jwt.claims was ever set
  -- for it) bypass the guard, exactly as specified. This is the plain test-runner session itself, not pg_temp.act.
  update public.products set item_code = 'RO-STD-04' where id = v_product;
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('S1 a service-role/migration write (auth.uid() is null) changes item_code without hitting the guard', v_code = 'RO-STD-04', coalesce(v_code, 'null'));

  -- A: anon cannot reach this trigger at all — it holds no table privilege on products whatsoever (20261016500000
  -- revoked all of it directly), so the auth.uid() is null bypass above is never reachable from an anon connection.
  perform pg_temp.chk('A1 anon has no UPDATE privilege on products at all',
    not has_table_privilege('anon', 'public.products', 'UPDATE'));
  perform pg_temp.chk('A2 ...nor SELECT, INSERT or DELETE (fully revoked, not just UPDATE)',
    not has_table_privilege('anon', 'public.products', 'SELECT')
    and not has_table_privilege('anon', 'public.products', 'INSERT')
    and not has_table_privilege('anon', 'public.products', 'DELETE'));

  -- I: a role that can write today (master) can still insert a brand-new product with item_code set; this
  -- migration adds no BEFORE INSERT trigger, so insert is completely untouched by it.
  x := pg_temp.act(m, format(
    'insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (%L, %L, %L, ''__TEST_product_new'', ''ro'', 500, ''RO-NEW-01'')',
    v_org, v_brand, v_model));
  perform pg_temp.chk('I1 master can still insert a new product with item_code set (insert is untouched by this migration)', x = 'ok:1', x);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
