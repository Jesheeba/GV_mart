-- DB tests for 20261226110000_gst_inclusive_toggle (F2). Run ONLY after the migration is applied,
-- as its own request (never concatenated with the migration). Ends in an unconditional RAISE,
-- so everything rolls back. Throwaway __TEST_ organisation only.
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
  v_org uuid; v_master uuid; v_cust uuid; v_spare uuid; r jsonb; inv invoices; q uuid; qrow quotations; n int;
  v_prod uuid; v_plan uuid; v_brand uuid; v_model uuid;
begin
  -- ACL: unchanged from before the migration
  perform pg_temp.chk('_sale_create_line_invoice: only service_role (no authenticated/anon/PUBLIC)',
    not has_function_privilege('authenticated', 'public._sale_create_line_invoice(uuid, uuid, invoice_type, jsonb, numeric, numeric, payment_method, text, text, numeric, boolean)', 'execute')
    and not has_function_privilege('anon', 'public._sale_create_line_invoice(uuid, uuid, invoice_type, jsonb, numeric, numeric, payment_method, text, text, numeric, boolean)', 'execute')
    and has_function_privilege('service_role', 'public._sale_create_line_invoice(uuid, uuid, invoice_type, jsonb, numeric, numeric, payment_method, text, text, numeric, boolean)', 'execute'));
  perform pg_temp.chk('one overload each of _sale_create_line_invoice and create_quotation',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_sale_create_line_invoice') = 1
    and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'create_quotation') = 1);
  perform pg_temp.chk('create_quotation: authenticated yes, anon no',
    has_function_privilege('authenticated', 'public.create_quotation(uuid, uuid, date, jsonb, uuid, boolean)', 'execute')
    and not has_function_privilege('anon', 'public.create_quotation(uuid, uuid, date, jsonb, uuid, boolean)', 'execute'));
  perform pg_temp.chk('create_sale / create_service_invoice / sell_amc_plan_onsite / create_rental keep authenticated, no anon',
    (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('create_sale', 'create_service_invoice', 'sell_amc_plan_onsite', 'create_rental')));
  perform pg_temp.chk('all 6 billing functions now call _gst_amount',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosrc like '%_gst_amount(%'
       and proname in ('_sale_create_line_invoice', 'create_sale', 'create_service_invoice', 'sell_amc_plan_onsite', 'create_rental', 'run_rental_billing')) = 6);

  -- _gst_amount math (same numbers as src/lib/gstInclusive.test.ts)
  perform pg_temp.chk('_gst_amount included 11800 @18 = 1800.00', public._gst_amount(11800, 18, true) = 1800.00);
  perform pg_temp.chk('_gst_amount included 12500 @18 = 1906.78', public._gst_amount(12500, 18, true) = 1906.78);
  perform pg_temp.chk('_gst_amount included 11250 @18 = 1716.10', public._gst_amount(11250, 18, true) = 1716.10);
  perform pg_temp.chk('_gst_amount extra 10000 @18 = 1800.00', public._gst_amount(10000, 18, false) = 1800.00);
  perform pg_temp.chk('_gst_amount rate 0 / null = 0', public._gst_amount(500, 0, true) = 0 and public._gst_amount(500, null, false) = 0);

  -- Fixtures
  insert into organizations (name) values ('__TEST_gst') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  -- New orgs default to a 5% admin discount cap; the 10% case needs 10 (tech max 10 too, so no approval row is created).
  update settings set gst_rate = 18, prices_include_gst = false, discount_admin_max = 10, discount_tech_max = 10 where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst customer', '9400009911') returning id into v_cust;
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 12500) returning id into v_spare;
  insert into inventory (org_id, item_type, item_id, location, stock_qty) values (v_org, 'spare', v_spare, 'warehouse', 10);

  perform pg_temp.chk('existing settings rows default prices_include_gst = false', (select not prices_include_gst from settings where org_id = v_org));

  -- create_sale: explicit Included
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_cust, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash', 'gst_inclusive', true));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('create_sale gst_inclusive=true: subtotal 12500, gst 1906.78, total 12500, flag stored',
    inv.subtotal = 12500 and inv.gst = 1906.78 and inv.total = 12500 and inv.gst_inclusive and inv.amount_paid = 12500,
    format('sub %s gst %s total %s paid %s', inv.subtotal, inv.gst, inv.total, inv.amount_paid));

  -- create_sale: explicit Extra (unchanged behaviour)
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_cust, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash', 'gst_inclusive', false));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('create_sale gst_inclusive=false: gst 2250, total 14750, flag false',
    inv.gst = 2250 and inv.total = 14750 and not inv.gst_inclusive, format('gst %s total %s', inv.gst, inv.total));

  -- create_sale: key absent -> org default (flip default to Included)
  update settings set prices_include_gst = true where org_id = v_org;
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_cust, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 10, 'payment_method', 'cash'));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('create_sale without gst_inclusive follows org default (Included), 10% discount: gst 1716.10, total 11250',
    inv.gst_inclusive and inv.discount = 1250 and inv.gst = 1716.10 and inv.total = 11250, format('disc %s gst %s total %s', inv.discount, inv.gst, inv.total));

  -- partial payment still bounded by the (inclusive) total
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_cust, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash', 'gst_inclusive', true), null, 0, null, 5000);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('partial payment on an Included bill: amount_paid 5000 of 12500, status partial',
    inv.amount_paid = 5000 and inv.total = 12500 and inv.payment_status::text = 'partial', format('%s / %s %s', inv.amount_paid, inv.total, inv.payment_status));

  -- create_quotation: explicit + default
  perform pg_temp.as_user(v_master);
  q := public.create_quotation(v_org, v_cust, null, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 2)), null, false);
  perform pg_temp.as_pg();
  select * into qrow from quotations where id = q;
  perform pg_temp.chk('create_quotation stores explicit false; total unchanged (25000)', qrow.gst_inclusive = false and qrow.total = 25000);
  perform pg_temp.as_user(v_master);
  q := public.create_quotation(v_org, v_cust, null, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)));
  perform pg_temp.as_pg();
  select * into qrow from quotations where id = q;
  perform pg_temp.chk('create_quotation without the arg follows org default (true)', qrow.gst_inclusive = true);
  select count(*) into n from quotations where gst_inclusive is null and org_id <> v_org;
  perform pg_temp.chk('pre-existing quotations stay NULL (legacy, print unchanged)', n = (select count(*) from quotations where org_id <> v_org), n::text);

  -- run_rental_billing uses org default
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, brand_id, model_id, name, category, price) values (v_org, v_brand, v_model, '__TEST_ rental RO', 'ro', 10000) returning id into v_prod;
  -- monthly_rate is generated: round(yearly_rate / 12, 2) -> 14160 / 12 = 1180.
  insert into rental_plans (org_id, name, yearly_rate) values (v_org, '__TEST_ plan', 14160) returning id into v_plan;
  insert into rental_contracts (org_id, customer_id, product_id, plan_id, start_date, status, next_billing_date)
    values (v_org, v_cust, v_prod, v_plan, current_date - 40, 'active', current_date - 1);
  n := public.run_rental_billing(v_org);
  select * into inv from invoices where org_id = v_org and type = 'rent' order by created_at desc limit 1;
  perform pg_temp.chk('run_rental_billing with org default Included: 1180 → gst 180.00, total 1180, flag true',
    n >= 1 and inv.gst = 180 and inv.total = 1180 and inv.gst_inclusive, format('n %s gst %s total %s', n, inv.gst, inv.total));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
