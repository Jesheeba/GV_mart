-- DB tests for 20270101100000_no_gst_bill. Run ONLY after the migration (rehearsal: same rolled-back request).
-- Ends in an unconditional RAISE, so everything rolls back. Throwaway __TEST_ organisation only.
-- Numbers @18%, org default Extra: spare 12500 -> Extra 2250/14750; No GST -> 0/12500 (10% discount -> 0/11250).
--   AMC plan 2000 -> Extra 360/2360; No GST 0/2000.  Service 1000 -> No GST 0/1000.  Rent 1000/month -> No GST 0/1000.
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
  v_org uuid; v_master uuid; v_tp uuid; v_tech uuid; v_tp2 uuid; v_tech2 uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid;
  v_brand uuid; v_model uuid; v_prod uuid; v_spare uuid; v_plan uuid; v_rplan uuid; v_addr uuid;
  v_t1 uuid; v_t2 uuid; v_vis1 uuid; v_vis2 uuid; v_q uuid; v_rc uuid;
  r jsonb; inv invoices; n int;
  c_fns constant text[] := array['create_quotation', 'create_rental', 'sell_amc_plan', 'sell_amc_plan_with_referrer', 'create_service_invoice', 'sell_amc_plan_onsite'];
begin
  -- ---------- AC5: signatures, ACLs, columns, existing data ----------
  perform pg_temp.chk('one overload each of the 6 re-signed functions',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = any(c_fns)) = 6
    and (select count(distinct proname) from pg_proc where pronamespace = 'public'::regnamespace and proname = any(c_fns)) = 6);
  perform pg_temp.chk('re-signed + create_sale: authenticated + service_role yes, anon no',
    (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')
                     and not has_function_privilege('anon', p.oid, 'execute'))
       from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname = any(c_fns) or p.proname = 'create_sale')));
  perform pg_temp.chk('run_rental_billing still service_role only',
    not has_function_privilege('authenticated', 'public.run_rental_billing(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.run_rental_billing(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.run_rental_billing(uuid)', 'execute'));
  perform pg_temp.chk('p_no_gst defaults NULL on all 6 (old callers + queued offline jobs unchanged)',
    (select bool_and(pg_get_function_arguments(p.oid) like '%p_no_gst boolean DEFAULT NULL::boolean')
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any(c_fns)));
  perform pg_temp.chk('quotations.no_gst + rental_contracts.no_gst: not null, default false',
    (select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'no_gst'
       and table_name in ('quotations', 'rental_contracts') and is_nullable = 'NO' and column_default = 'false') = 2);
  perform pg_temp.chk('existing quotations + rental contracts all no_gst = false',
    not exists (select 1 from quotations where no_gst) and not exists (select 1 from rental_contracts where no_gst));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_no_gst') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update settings set gst_rate = 18, prices_include_gst = false, discount_admin_max = 10, discount_tech_max = 10 where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ nogst c1', '5550300001') returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ nogst c2', '5550300002') returning id into v_c2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ nogst c3', '5550300003') returning id into v_c3;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ nogst c4', '5550300004') returning id into v_c4;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ nogst c5', '5550300005') returning id into v_c5;
  insert into addresses (org_id, customer_id, address_type, is_primary) values (v_org, v_c5, 'residential', true) returning id into v_addr;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'product', v_prod, 5, 'warehouse');
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 12500) returning id into v_spare;
  insert into inventory (org_id, item_type, item_id, location, stock_qty) values (v_org, 'spare', v_spare, 'warehouse', 10);
  insert into amc_plans (org_id, name, years, price, price_per_year, visits_per_year) values (v_org, '__TEST_ AMC', 1, 2000, 2000, 2) returning id into v_plan;
  insert into rental_plans (org_id, name, visits_per_year, yearly_rate, duration_years) values (v_org, '__TEST_ rent', 4, 12000, 1) returning id into v_rplan;

  -- ---------- AC1/AC2: New Sale ----------
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash', 'no_gst', true));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('AC1 create_sale no_gst: subtotal 12500, gst 0, total 12500, paid in full',
    inv.subtotal = 12500 and inv.gst = 0 and inv.total = 12500 and inv.amount_paid = 12500 and inv.payment_status::text = 'paid',
    format('%s/%s/%s paid %s', inv.subtotal, inv.gst, inv.total, inv.amount_paid));

  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 10, 'payment_method', 'cash', 'no_gst', true, 'gst_inclusive', true));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('AC1 create_sale no_gst + 10% discount (+ stray gst_inclusive): gst 0, total 11250',
    inv.discount = 1250 and inv.gst = 0 and inv.total = 11250, format('disc %s gst %s total %s', inv.discount, inv.gst, inv.total));

  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash', 'no_gst', false));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('AC2 create_sale no_gst=false: unchanged Extra 2250 / 14750', inv.gst = 2250 and inv.total = 14750, format('%s/%s', inv.gst, inv.total));

  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
         'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash'));
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'spare_invoice_id')::uuid;
  perform pg_temp.chk('AC2 create_sale without no_gst key (old app): org default Extra 2250 / 14750', inv.gst = 2250 and inv.total = 14750, format('%s/%s', inv.gst, inv.total));

  -- ---------- AC4: quotation stores the choice ----------
  perform pg_temp.as_user(v_master);
  v_q := public.create_quotation(v_org, v_c1, null, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)), null, false, true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC4 create_quotation p_no_gst=true is stored', (select no_gst from quotations where id = v_q));
  perform pg_temp.as_user(v_master);
  v_q := public.create_quotation(v_org, v_c1, null, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)), null, false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC2 create_quotation old call shape: no_gst false', (select not no_gst from quotations where id = v_q));

  -- ---------- AC1: admin Sell AMC + referrer wrapper ----------
  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan(v_org, v_c2, v_prod, v_plan, p_payment_method => 'cash', p_no_gst => true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC1 sell_amc_plan no_gst: amc 2000, gst 0, total 2000, paid',
    inv.type::text = 'amc' and inv.gst = 0 and inv.total = 2000 and inv.payment_status::text = 'paid', format('%s/%s %s', inv.gst, inv.total, inv.payment_status));
  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan_with_referrer(v_org, v_c3, v_prod, v_plan, p_payment_method => 'cash', p_no_gst => true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC1 sell_amc_plan_with_referrer passes no_gst through: total 2000, gst 0', inv.gst = 0 and inv.total = 2000, format('%s/%s', inv.gst, inv.total));
  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan(v_org, v_c4, v_prod, v_plan);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC2 sell_amc_plan old call shape: Extra 360 / 2360', inv.gst = 360 and inv.total = 2360, format('%s/%s', inv.gst, inv.total));

  -- ---------- AC1: technician on-site AMC + service invoice ----------
  perform pg_temp.as_user(v_tp);
  r := public.sell_amc_plan_onsite(v_org, v_c5, v_prod, v_plan, 'cash', null, null, null, null, true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC1 sell_amc_plan_onsite no_gst: gst 0, total 2000', inv.gst = 0 and inv.total = 2000, format('%s/%s', inv.gst, inv.total));

  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_c1, v_prod, 'paid', '__TEST_ repair 1') returning id into v_t1;
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_c2, v_prod, 'paid', '__TEST_ repair 2') returning id into v_t2;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t1, v_tech) returning id into v_vis1;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t2, v_tech2) returning id into v_vis2;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_t1, 'always', v_tech, 'in_progress');
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_t2, 'always', v_tech2, 'in_progress');
  perform pg_temp.as_user(v_tp);
  r := public.create_service_invoice(v_org, v_vis1, 1000, 0, '[]'::jsonb, 'cash', null, null, true, null, '[]'::jsonb, null, true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC1 create_service_invoice no_gst: gst 0, total 1000, paid 1000',
    inv.gst = 0 and inv.total = 1000 and inv.amount_paid = 1000 and (r ->> 'total')::numeric = 1000, format('%s/%s paid %s', inv.gst, inv.total, inv.amount_paid));
  perform pg_temp.as_user(v_tp2);
  r := public.create_service_invoice(v_org, v_vis2, 1000, 0, '[]'::jsonb, 'cash', null, null, true, null, '[]'::jsonb);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('AC2 create_service_invoice old call shape (queued offline job): Extra 180 / 1180', inv.gst = 180 and inv.total = 1180, format('%s/%s', inv.gst, inv.total));

  -- ---------- AC3: rentals ----------
  perform pg_temp.as_user(v_master);
  r := public.create_rental(v_org, v_c5, v_prod, v_rplan, v_addr, current_date, 'cash', null, null, null, true);
  perform pg_temp.as_pg();
  v_rc := (r ->> 'contract_id')::uuid;
  select * into inv from invoices where id = (select invoice_id from rental_contracts where id = v_rc);
  perform pg_temp.chk('AC3 create_rental no_gst: month 1 = 1000, gst 0; contract stores no_gst',
    inv.total = 1000 and inv.gst = 0 and (select no_gst from rental_contracts where id = v_rc), format('%s/%s', inv.gst, inv.total));
  update rental_contracts set next_billing_date = current_date - 1 where id = v_rc;
  insert into rental_contracts (org_id, customer_id, product_id, plan_id, start_date, status, next_billing_date)
    values (v_org, v_c4, v_prod, v_rplan, current_date - 40, 'active', current_date - 1);
  n := public.run_rental_billing(v_org);
  select * into inv from invoices where org_id = v_org and type = 'rent' and customer_id = v_c5 and payment_method is null;
  perform pg_temp.chk('AC3 run_rental_billing follows the no-GST contract: 1000, gst 0, due',
    n = 2 and inv.total = 1000 and inv.gst = 0 and inv.payment_status::text = 'due', format('n %s %s/%s', n, inv.gst, inv.total));
  select * into inv from invoices where org_id = v_org and type = 'rent' and customer_id = v_c4;
  perform pg_temp.chk('AC2 run_rental_billing: contract without no_gst stays Extra 1180', inv.total = 1180 and inv.gst = 180, format('%s/%s', inv.gst, inv.total));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
