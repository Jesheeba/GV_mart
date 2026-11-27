-- DB tests for 20270104100000_exact_rupee_discount. Run in the same request as the migration; ends in RAISE (rolls back).
-- Throwaway __TEST_ organisation only.
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
  v_org uuid; v_master uuid; v_c1 uuid; v_brand uuid; v_model uuid; v_prod uuid; v_spare uuid;
  r jsonb; v_disc numeric; v_err text; v_pct numeric := 2000::numeric / 31000 * 100;
begin
  insert into organizations (name) values ('__TEST_exact_rupee') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update settings set gst_rate = 18, prices_include_gst = false, discount_admin_max = 10, discount_tech_max = 5 where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ exact c1', '5550500001') returning id into v_c1;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 21000) returning id into v_prod;
  insert into inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'product', v_prod, 5, 'warehouse');
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 10000) returning id into v_spare;
  insert into inventory (org_id, item_type, item_id, location, stock_qty) values (v_org, 'spare', v_spare, 'warehouse', 5);

  perform pg_temp.chk('create_sale: one overload, authenticated yes, anon no',
    (select count(*) = 1 and bool_and(has_function_privilege('authenticated', oid, 'execute') and not has_function_privilege('anon', oid, 'execute'))
       from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_sale'));

  -- ₹2000 off ₹31000 (product 21000 + spare 10000), sent as the exact % the sale screen computes
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object(
         'product_items', jsonb_build_array(jsonb_build_object('item_id', v_prod, 'qty', 1)),
         'spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'amc', null, 'discount_percent', v_pct, 'payment_method', 'cash'));
  perform pg_temp.as_pg();
  select sum(discount) into v_disc from invoices where id in ((r ->> 'product_invoice_id')::uuid, (r ->> 'spare_invoice_id')::uuid);
  perform pg_temp.chk('exact ₹: product + spare bill discounts add up to exactly 2000.00 (was 1999.50 at 6.45%)', v_disc = 2000, v_disc::text);
  perform pg_temp.chk('6.45% (> tech max 5) still raises an owner approval',
    exists (select 1 from approvals where org_id = v_org and type::text = 'discount'));

  begin
    perform pg_temp.as_user(v_master);
    r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
           'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 10.0001, 'payment_method', 'cash'));
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('cap still holds: 10.0001% refused (no longer rounded down to 10.00)', v_err like '%exceeds the admin limit%', v_err);

  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 5, 'payment_method', 'cash'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('plain 5% unchanged: 10000 → discount 500.00',
    (select discount from invoices where id = (r ->> 'spare_invoice_id')::uuid) = 500);

  begin
    perform public._check_quotation_discount(v_org, 333.35, 33.34, 'x');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('quotation cap rounds DOWN: 33.34 on 333.35 (10.002%) refused', v_err like '%percent of the subtotal%', v_err);
  begin
    perform public._check_quotation_discount(v_org, 333.35, 33.33, 'x');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('quotation cap: 33.33 on 333.35 allowed', v_err = 'no error', v_err);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
