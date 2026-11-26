-- DB tests for 20261226120000_quick_add_lead_option (F3b). Run ONLY after the migration is applied, as its own
-- request (never concatenated with the migration). Ends in an unconditional RAISE, so everything rolls back.
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
  v_org uuid; v_org2 uuid; v_master uuid; v_sales uuid; v_ops uuid; v_tech uuid; v_m2 uuid; k text; k2 text; s text; n int;
begin
  insert into organizations (name) values ('__TEST_leadopt') returning id into v_org;
  insert into organizations (name) values ('__TEST_leadopt_other') returning id into v_org2;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tech := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);

  perform pg_temp.chk('ACL: anon and PUBLIC cannot execute, authenticated can',
    not has_function_privilege('anon', 'public.quick_add_lead_option(text, text)', 'execute')
    and has_function_privilege('authenticated', 'public.quick_add_lead_option(text, text)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.proname = 'quick_add_lead_option' and a.grantee = 0));

  -- sales_admin adds a source; key rule matches Masters (src/lib/lead-sources.ts)
  perform pg_temp.as_user(v_sales);
  k := public.quick_add_lead_option('source', '  Walk-in  Customer ');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin adds a source: key walk_in_customer, label tidied, active, not system, own org',
    k = 'walk_in_customer' and exists (select 1 from lead_sources where org_id = v_org and key = k and label = 'Walk-in Customer' and is_active and not is_system), k);

  -- same label any case -> existing key, no duplicate
  perform pg_temp.as_user(v_master);
  k2 := public.quick_add_lead_option('source', 'WALK-IN customer');
  perform pg_temp.as_pg();
  select count(*) into n from lead_sources where org_id = v_org and key = 'walk_in_customer';
  perform pg_temp.chk('same name again returns the existing key, no duplicate row', k2 = k and n = 1, n::text);

  -- kind and product_type lists
  perform pg_temp.as_user(v_sales);
  k := public.quick_add_lead_option('kind', 'Bulk Order');
  k2 := public.quick_add_lead_option('product_type', 'RO / UV');
  perform pg_temp.as_pg();
  perform pg_temp.chk('kind and product_type are written to their own tables',
    exists (select 1 from lead_kinds where org_id = v_org and key = 'bulk_order')
    and exists (select 1 from lead_product_types where org_id = v_org and key = 'ro_uv') and k = 'bulk_order' and k2 = 'ro_uv');

  -- archived option is not silently re-enabled
  update lead_kinds set is_active = false where org_id = v_org and key = 'bulk_order';
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.quick_add_lead_option('kind', 'bulk order')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('archived option raises "archived" and stays archived',
    s = 'archived' and not (select is_active from lead_kinds where org_id = v_org and key = 'bulk_order'), coalesce(s, 'no error'));

  -- another org's option is not reused
  perform pg_temp.as_user(v_m2);
  k := public.quick_add_lead_option('source', 'Walk-in Customer');
  perform pg_temp.as_pg();
  perform pg_temp.chk('other org gets its own row (no cross-org reuse)', exists (select 1 from lead_sources where org_id = v_org2 and key = k));

  -- roles refused
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises($q$select public.quick_add_lead_option('source', 'X')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin refused (leads are sales-only)', s like '%not allowed%', coalesce(s, 'no error'));
  perform pg_temp.as_user(v_tech);
  s := pg_temp.raises($q$select public.quick_add_lead_option('source', 'X')$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('technician refused', s like '%not allowed%', coalesce(s, 'no error'));

  -- bad input
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.quick_add_lead_option('outcome', 'X')$q$);
  perform pg_temp.chk('unknown list rejected (no table injection)', s like '%unknown list%', coalesce(s, 'no error'));
  s := pg_temp.raises($q$select public.quick_add_lead_option('source', '   ')$q$);
  perform pg_temp.chk('blank label rejected', s like '%1-60%', coalesce(s, 'no error'));
  s := pg_temp.raises($q$select public.quick_add_lead_option('source', repeat('a', 61))$q$);
  perform pg_temp.chk('61-char label rejected', s like '%1-60%', coalesce(s, 'no error'));
  s := pg_temp.raises($q$select public.quick_add_lead_option('source', '!!!')$q$);
  perform pg_temp.chk('label with no letters/digits rejected', s like '%letter or digit%', coalesce(s, 'no error'));
  -- RLS unchanged: sales_admin still can't write the table directly
  s := pg_temp.raises(format($q$update public.lead_sources set label = 'hacked' where org_id = %L and key = 'walk_in_customer'$q$, v_org));
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin direct UPDATE still blocked/no-op by RLS',
    (select label from lead_sources where org_id = v_org and key = 'walk_in_customer') = 'Walk-in Customer', coalesce(s, 'no error, 0 rows'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r3.line, E'\n' order by r3.n) from pg_temp.res r3);
end $t$;
