-- DB tests for 20261226100000_quick_add_complaint_type (F3 quick-add). NOT RUN until owner GO APPLY.
-- Run as: migration text, then this file, in ONE request — it ends in an unconditional RAISE so everything rolls back.
-- Throwaway __TEST_ organisations only.
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
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tech uuid; v_m2 uuid;
  r public.complaint_types; r2 public.complaint_types; s text; n int;
begin
  insert into organizations (name) values ('__TEST_quickadd') returning id into v_org;
  insert into organizations (name) values ('__TEST_quickadd_other') returning id into v_org2;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tech := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);

  perform pg_temp.chk('ACL: anon and PUBLIC cannot execute, authenticated can',
    not has_function_privilege('anon', 'public.quick_add_complaint_type(text, public.brand_category)', 'execute')
    and has_function_privilege('authenticated', 'public.quick_add_complaint_type(text, public.brand_category)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.proname = 'quick_add_complaint_type' and a.grantee = 0));

  -- AC: operation_admin can add; label trimmed and spaces collapsed; org from session
  perform pg_temp.as_user(v_ops);
  r := public.quick_add_complaint_type('  Low   water flow ', 'ro');
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin adds a category-level complaint name in own org',
    r.org_id = v_org and r.label = 'Low water flow' and r.product_category = 'ro' and r.product_id is null, coalesce(r.label, 'null'));

  -- AC: duplicate never inserted (case-insensitive) — existing row returned
  perform pg_temp.as_user(v_master);
  r2 := public.quick_add_complaint_type('LOW WATER FLOW', 'ro');
  perform pg_temp.as_pg();
  select count(*) into n from complaint_types where org_id = v_org and lower(label) = 'low water flow';
  perform pg_temp.chk('same name different case returns existing row, no duplicate', r2.id = r.id and n = 1, n::text);

  -- same name in another category is a different complaint
  perform pg_temp.as_user(v_master);
  r2 := public.quick_add_complaint_type('Low water flow', 'ac');
  perform pg_temp.as_pg();
  perform pg_temp.chk('same name in another category inserts a new row', r2.id <> r.id and r2.product_category = 'ac');

  -- other org's master doesn't see/reuse this org's row
  perform pg_temp.as_user(v_m2);
  r2 := public.quick_add_complaint_type('Low water flow', 'ro');
  perform pg_temp.as_pg();
  perform pg_temp.chk('other org gets its own row (no cross-org reuse)', r2.org_id = v_org2 and r2.id <> r.id);

  -- AC: unauthorised roles rejected
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.quick_add_complaint_type('X', 'ro')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin rejected', s like '%not allowed%', coalesce(s, 'no error'));
  perform pg_temp.as_user(v_tech);
  s := pg_temp.raises($q$select public.quick_add_complaint_type('X', 'ro')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('technician rejected', s like '%not allowed%', coalesce(s, 'no error'));

  -- edge cases: blank, too long, null category
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises($q$select public.quick_add_complaint_type('   ', 'ro')$q$);
  perform pg_temp.chk('blank label rejected', s like '%1-120%', coalesce(s, 'no error'));
  s := pg_temp.raises($q$select public.quick_add_complaint_type(repeat('a', 121), 'ro')$q$);
  perform pg_temp.chk('121-char label rejected', s like '%1-120%', coalesce(s, 'no error'));
  s := pg_temp.raises($q$select public.quick_add_complaint_type('Leak', null)$q$);
  perform pg_temp.chk('null category rejected', s like '%category required%', coalesce(s, 'no error'));
  -- operation_admin still can't write complaint_types directly (RLS unchanged)
  s := pg_temp.raises(format($q$update public.complaint_types set label = 'hacked' where id = %L$q$, r.id));
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin direct UPDATE still blocked/no-op by RLS',
    (select label from complaint_types where id = r.id) = 'Low water flow', coalesce(s, 'no error, 0 rows'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r3.line, E'\n' order by r3.n) from pg_temp.res r3);
end $t$;
