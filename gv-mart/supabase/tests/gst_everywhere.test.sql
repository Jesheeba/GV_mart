-- DB tests for 20261230100000_gst_everywhere. Run ONLY after the migration is applied,
-- as its own request (never concatenated with the migration). Ends in an unconditional RAISE,
-- so everything rolls back. Throwaway __TEST_ organisation only.
-- Numbers: plan 2000 @18%  Extra -> gst 360, total 2360;  Included -> gst 305.08, total 2000.
--          1000 @18%       Extra -> gst 180, total 1180;  Included -> gst 152.54, total 1000.
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
  v_org uuid; v_master uuid; v_tp uuid; v_tech uuid; v_tp2 uuid; v_tech2 uuid; v_custu uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid; v_c6 uuid;
  v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid; v_rplan uuid; v_addr uuid;
  v_t1 uuid; v_t2 uuid; v_vis1 uuid; v_vis2 uuid;
  r jsonb; inv invoices; v_err text; n int; v_rc uuid;
begin
  -- ---------- signatures + ACLs ----------
  perform pg_temp.chk('one overload each of the 5 re-signed functions',
    (select bool_and(c = 1) from (select count(*) c from pg_proc where pronamespace = 'public'::regnamespace
       and proname in ('create_service_invoice', 'sell_amc_plan_onsite', 'create_rental', 'sell_amc_plan', 'sell_amc_plan_with_referrer') group by proname) x)
    and (select count(distinct proname) from pg_proc where pronamespace = 'public'::regnamespace
       and proname in ('create_service_invoice', 'sell_amc_plan_onsite', 'create_rental', 'sell_amc_plan', 'sell_amc_plan_with_referrer')) = 5);
  perform pg_temp.chk('re-signed functions: authenticated + service_role yes, anon no',
    (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('service_role', p.oid, 'execute')
                     and not has_function_privilege('anon', p.oid, 'execute'))
       from pg_proc p where p.pronamespace = 'public'::regnamespace
        and p.proname in ('create_service_invoice', 'sell_amc_plan_onsite', 'create_rental', 'sell_amc_plan', 'sell_amc_plan_with_referrer')));
  perform pg_temp.chk('run_rental_billing still service_role only (no authenticated)',
    not has_function_privilege('authenticated', 'public.run_rental_billing(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.run_rental_billing(uuid)', 'execute'));
  perform pg_temp.chk('new params all default NULL (old callers + queued offline jobs unchanged)',
    (select bool_and(pg_get_function_arguments(p.oid) like '%p_gst_inclusive boolean DEFAULT NULL::boolean%')
       from pg_proc p where p.pronamespace = 'public'::regnamespace
        and p.proname in ('create_service_invoice', 'sell_amc_plan_onsite', 'create_rental', 'sell_amc_plan', 'sell_amc_plan_with_referrer')));
  perform pg_temp.chk('rental_contracts.gst_inclusive exists and is nullable',
    (select is_nullable = 'YES' from information_schema.columns where table_schema = 'public' and table_name = 'rental_contracts' and column_name = 'gst_inclusive'));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_gst_everywhere') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update settings set gst_rate = 18, prices_include_gst = false, discount_admin_max = 10, discount_tech_max = 10 where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_custu := pg_temp.mkuser('customer', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  -- one open untimed appointment per technician (appointments_one_open_untimed_per_technician_idx), so visit 2 gets its own
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst c1', '5550200001') returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst c2', '5550200002') returning id into v_c2;
  insert into customers (org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_ gst self', '5550200003', v_custu) returning id into v_c3;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst c4', '5550200004') returning id into v_c4;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst c5', '5550200005') returning id into v_c5;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ gst c6', '5550200006') returning id into v_c6;
  insert into addresses (org_id, customer_id, address_type, is_primary) values (v_org, v_c5, 'residential', true) returning id into v_addr;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'product', v_prod, 5, 'warehouse');
  insert into amc_plans (org_id, name, years, price, price_per_year, visits_per_year) values (v_org, '__TEST_ AMC', 1, 2000, 2000, 2) returning id into v_plan;
  insert into rental_plans (org_id, name, visits_per_year, yearly_rate, duration_years) values (v_org, '__TEST_ rent', 4, 12000, 1) returning id into v_rplan;

  -- ---------- admin Sell AMC (sell_amc_plan) ----------
  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan(v_org, v_c1, v_prod, v_plan);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('sell_amc_plan, no payment, default Extra: amc invoice 2000 + 360 = 2360, DUE, paid 0',
    inv.type::text = 'amc' and inv.subtotal = 2000 and inv.gst = 360 and inv.total = 2360 and not inv.gst_inclusive
    and inv.payment_status::text = 'due' and inv.amount_paid = 0 and inv.payment_method is null and (r ->> 'total')::numeric = 2360,
    format('%s %s/%s/%s %s', inv.type, inv.subtotal, inv.gst, inv.total, inv.payment_status));
  perform pg_temp.chk('sell_amc_plan links the invoice to the contract',
    (select invoice_id from amc_contracts where id = (r ->> 'contract_id')::uuid) = inv.id);

  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan(v_org, v_c2, v_prod, v_plan, p_years => 2, p_payment_method => 'cash', p_gst_inclusive => true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('sell_amc_plan 2 years, cash, Included: subtotal 4000, gst 610.17, total 4000, PAID',
    inv.subtotal = 4000 and inv.gst = 610.17 and inv.total = 4000 and inv.gst_inclusive and inv.payment_status::text = 'paid' and inv.amount_paid = 4000,
    format('%s/%s/%s %s', inv.subtotal, inv.gst, inv.total, inv.payment_status));

  v_err := null;
  begin
    perform pg_temp.as_user(v_master);
    perform public.sell_amc_plan(v_org, v_c4, v_prod, v_plan, p_payment_method => 'transfer');
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('sell_amc_plan bank transfer without txn id is refused', v_err like '%bank transfer requires%', coalesce(v_err, 'no error'));

  perform pg_temp.as_user(v_master);
  r := public.sell_amc_plan_with_referrer(v_org, v_c4, v_prod, v_plan, p_payment_method => 'upi', p_txn_id => 'U-TEST-1', p_gst_inclusive => false);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('sell_amc_plan_with_referrer passes payment + GST through: 2360 paid by upi, txn kept',
    inv.total = 2360 and inv.payment_status::text = 'paid' and inv.payment_method::text = 'upi' and inv.txn_id = 'U-TEST-1',
    format('%s %s %s %s', inv.total, inv.payment_status, inv.payment_method, inv.txn_id));

  -- ---------- technician on-site AMC ----------
  perform pg_temp.as_user(v_tp);
  r := public.sell_amc_plan_onsite(v_org, v_c5, v_prod, v_plan, 'cash', null, null, null, true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('sell_amc_plan_onsite Included: gst 305.08, total 2000, flag true',
    inv.gst = 305.08 and inv.total = 2000 and inv.gst_inclusive, format('%s/%s', inv.gst, inv.total));
  perform pg_temp.as_user(v_tp);
  r := public.sell_amc_plan_onsite(v_org, v_c6, v_prod, v_plan, 'cash');
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('sell_amc_plan_onsite old call shape follows org default (Extra 2360)',
    inv.gst = 360 and inv.total = 2360 and not inv.gst_inclusive, format('%s/%s', inv.gst, inv.total));

  -- ---------- technician on-site service invoice ----------
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_c1, v_prod, 'paid', '__TEST_ repair 1') returning id into v_t1;
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_c2, v_prod, 'paid', '__TEST_ repair 2') returning id into v_t2;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t1, v_tech) returning id into v_vis1;
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t2, v_tech2) returning id into v_vis2;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_t1, 'always', v_tech, 'in_progress');
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_t2, 'always', v_tech2, 'in_progress');
  perform pg_temp.as_user(v_tp);
  r := public.create_service_invoice(v_org, v_vis1, 1000, 0, '[]'::jsonb, 'cash', null, null, true, null, '[]'::jsonb, true);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('create_service_invoice Included: 1000 -> gst 152.54, total 1000, paid 1000',
    inv.gst = 152.54 and inv.total = 1000 and inv.gst_inclusive and inv.amount_paid = 1000 and (r ->> 'total')::numeric = 1000,
    format('%s/%s paid %s', inv.gst, inv.total, inv.amount_paid));
  perform pg_temp.as_user(v_tp2);
  r := public.create_service_invoice(v_org, v_vis2, 1000, 0, '[]'::jsonb, 'upi', null, null, true, 0, '[]'::jsonb);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('create_service_invoice old call shape -> org default Extra 1180; upi starts due',
    inv.gst = 180 and inv.total = 1180 and not inv.gst_inclusive and inv.payment_status::text = 'due',
    format('%s/%s %s', inv.gst, inv.total, inv.payment_status));

  -- ---------- rentals ----------
  perform pg_temp.as_user(v_master);
  r := public.create_rental(v_org, v_c5, v_prod, v_rplan, v_addr, current_date, 'cash', null, null, true);
  perform pg_temp.as_pg();
  v_rc := (r ->> 'contract_id')::uuid;
  select * into inv from invoices where id = (select invoice_id from rental_contracts where id = v_rc);
  perform pg_temp.chk('create_rental Included: month 1 = 1000, gst 152.54; contract stores gst_inclusive true',
    inv.total = 1000 and inv.gst = 152.54 and inv.gst_inclusive and (select gst_inclusive from rental_contracts where id = v_rc),
    format('%s/%s', inv.gst, inv.total));
  update rental_contracts set next_billing_date = current_date - 1 where id = v_rc;
  insert into rental_contracts (org_id, customer_id, product_id, plan_id, start_date, status, next_billing_date)
    values (v_org, v_c6, v_prod, v_rplan, current_date - 40, 'active', current_date - 1);
  n := public.run_rental_billing(v_org);
  -- the cron bill, not month 1: same created_at inside one transaction, and the cron leaves payment_method null
  select * into inv from invoices where org_id = v_org and type = 'rent' and customer_id = v_c5 and payment_method is null;
  perform pg_temp.chk('run_rental_billing follows the contract (Included 1000) while org default is Extra',
    n = 2 and inv.total = 1000 and inv.gst_inclusive and inv.payment_status::text = 'due', format('n %s total %s', n, inv.total));
  select * into inv from invoices where org_id = v_org and type = 'rent' and customer_id = v_c6;
  perform pg_temp.chk('run_rental_billing: older contract (NULL) follows org default (Extra 1180)',
    inv.total = 1180 and not inv.gst_inclusive, format('total %s', inv.total));

  -- ---------- customer-app renewal ----------
  perform pg_temp.as_user(v_custu);
  r := public.renew_amc_plan(v_org, v_prod, v_plan, 'TEST-REF-GST');
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'invoice_id')::uuid;
  perform pg_temp.chk('renew_amc_plan: amc invoice 2360 (org default Extra), DUE (payment is simulated), reference kept',
    inv.type::text = 'amc' and inv.customer_id = v_c3 and inv.total = 2360 and inv.gst = 360 and inv.payment_status::text = 'due'
    and inv.amount_paid = 0 and inv.payment_method is null and inv.txn_id = 'TEST-REF-GST' and inv.sold_by is null,
    format('%s %s %s %s', inv.total, inv.payment_status, inv.payment_method, inv.txn_id));
  perform pg_temp.chk('renew_amc_plan links the invoice to the contract',
    (select invoice_id from amc_contracts where id = (r ->> 'contract_id')::uuid) = inv.id);
  perform pg_temp.as_user(v_custu);
  r := public.get_customer_app_settings(v_org);
  perform pg_temp.as_pg();
  perform pg_temp.chk('get_customer_app_settings returns gst_rate 18 + prices_include_gst false, still no discount caps',
    (r ->> 'gst_rate')::numeric = 18 and (r ->> 'prices_include_gst')::boolean = false and not (r ? 'discount_admin_max'), r::text);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
