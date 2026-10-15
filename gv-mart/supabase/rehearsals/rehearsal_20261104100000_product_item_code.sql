-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): product item code, with unique index (P4): migration 20261104100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()),
-- (2) recomputes the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) recomputes
-- a RELATIVE fingerprint of the real organisation (its id + name, picking the earliest non-__TEST-named row — not an
-- exact snapshot of the whole table, so it survives new test orgs being added later) and refuses on any mismatch,
-- confirming this rehearsal is pointed at the real project,
-- (4) executes the migration text(s) and then the test file in order, (5) always ends in an unconditional RAISE
-- EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with
-- test code outside this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure
-- and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c  gv-mart/supabase/migrations/20261104100000_product_item_code.sql
--   4dd53e550b2dd1d03ad728aecbdbbfc93dc4cef082996974f633224f823b24a0  gv-mart/supabase/tests/product_item_code.test.sql
-- Pinned (relative fingerprint of the real organisation; read-only, confirmed against the live project):
--   6f891cf85011f08c2f22fb4a208d21bd  md5(organizations.id || '|' || organizations.name) of the earliest non-__TEST row

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
  v_check text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  select md5(o.id::text || '|' || o.name) into v_check
    from public.organizations o
   where o.name not like '\_\_TEST%'
   order by o.created_at asc
   limit 1;
  if v_check is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected the real GV Mart org, got %)', coalesce(v_check, 'null');
  end if;

  v_text := $rh0$-- P4: an identification code per PRODUCT (spares already have one — `spares.sku`, 20260701090300). This is a
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
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '117108956dc0f12c49068c46e0a1ff2a4b489082d185e6ecaeb443acbf87ad0c' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261104100000_product_item_code.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for 20261104100000_product_item_code (P4).
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
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '4dd53e550b2dd1d03ad728aecbdbbfc93dc4cef082996974f633224f823b24a0' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for product_item_code.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
