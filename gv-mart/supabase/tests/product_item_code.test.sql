-- Rolled-back DB tests for 20261104100000_product_item_code (P4).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
create function pg_temp.seen(p_uid uuid, p_sql text) returns int language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute 'select count(*) from (' || p_sql || ') q' into n;
  execute 'reset role';
  return n;
exception when others then
  execute 'reset role';
  return -1;
end $f$;

do $t$
declare
  v_org uuid; m uuid; o uuid; s uuid; c uuid; v_brand uuid; v_model uuid; v_product uuid; x text; v_code text;
begin
  insert into public.organizations(name) values ('__TEST_p4') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); o := pg_temp.mkuser('operation_admin', v_org);
  s := pg_temp.mkuser('sales_admin', v_org); c := pg_temp.mkuser('customer', v_org);

  perform pg_temp.chk('C1 products has item_code (nullable text, no DB-level check — matches spares.sku exactly)',
    (select data_type || '/' || is_nullable from information_schema.columns
       where table_schema = 'public' and table_name = 'products' and column_name = 'item_code') = 'text/YES'
    and not exists (select 1 from information_schema.check_constraints cc
                     join information_schema.constraint_column_usage ccu on ccu.constraint_name = cc.constraint_name
                     where ccu.table_name = 'products' and ccu.column_name = 'item_code'));

  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;
  insert into public.products(org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_product', 'ro', 1000) returning id into v_product;

  perform pg_temp.chk('C2 item_code is null by default (no backfill)', (select item_code is null from public.products where id = v_product));

  x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-01'' where id = %L', v_product));
  perform pg_temp.chk('W1 master can set the item code', x = 'ok:1', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('W1b the value round-trips', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  x := pg_temp.act(o, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('W2 operation_admin cannot set it (products_write_master is master-only, unchanged)', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(s, format('update public.products set item_code = ''HACKED'' where id = %L', v_product));
  perform pg_temp.chk('W3 sales_admin cannot set it', x = 'ok:0' or x like 'err:%', x);
  select item_code into v_code from public.products where id = v_product;
  perform pg_temp.chk('W4 the value is still what master set (W2/W3 changed nothing)', v_code = 'RO-STD-01', coalesce(v_code, 'null'));

  perform pg_temp.chk('R1 every org member can READ item_code, same as every other product column (products_select_org, unchanged)',
    pg_temp.seen(o, format('select 1 from public.products where id = %L and item_code = ''RO-STD-01''', v_product)) = 1
    and pg_temp.seen(s, format('select 1 from public.products where id = %L and item_code = ''RO-STD-01''', v_product)) = 1
    and pg_temp.seen(c, format('select 1 from public.products where id = %L and item_code = ''RO-STD-01''', v_product)) = 1);

  x := pg_temp.act(m, format('update public.products set item_code = null where id = %L', v_product));
  perform pg_temp.chk('W5 master can clear it back to null', x = 'ok:1', x);

  -- U: the partial unique index
  declare
    v_product2 uuid; v_product3 uuid;
  begin
    insert into public.products(org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_product2', 'ro', 1000) returning id into v_product2;
    insert into public.products(org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_product3', 'ro', 1000) returning id into v_product3;
    x := pg_temp.act(m, format('update public.products set item_code = ''RO-STD-01'' where id = %L', v_product2));
    perform pg_temp.chk('U1 setting a first product''s code succeeds', x = 'ok:1', x);
    x := pg_temp.act(m, format('update public.products set item_code = ''ro-std-01'' where id = %L', v_product3));
    perform pg_temp.chk('U2 a different-case duplicate in the SAME org is refused (case-insensitive unique)', x like 'err:%', x);
    perform pg_temp.chk('U3 multiple products with item_code still null is fine (partial index)',
      (select count(*) from public.products where org_id = v_org and item_code is null) >= 1);
  end;

  declare
    v_org2 uuid; v_other_product uuid;
  begin
    insert into public.organizations(name) values ('__TEST_p4_other') returning id into v_org2;
    insert into public.products(org_id, brand_id, model_id, name, category, price, item_code) values (v_org2, v_brand, v_model, '__TEST_other_org', 'ro', 1000, 'RO-STD-01') returning id into v_other_product;
    perform pg_temp.chk('U4 the SAME code in a DIFFERENT org is fine (index is org-scoped)',
      (select count(*) from public.products where item_code is not null and lower(item_code) = 'ro-std-01') = 2);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
