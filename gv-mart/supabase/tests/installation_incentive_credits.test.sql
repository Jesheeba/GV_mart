-- Rolled-back DB tests for migration 20261016120000_installation_incentive_credits (batch-2 item 3).
-- Run AFTER 20261016110000_test_customer_flag (the runner script concatenates both migrations in front of this file inside one
-- transaction). One transaction ending in RAISE; read RESULTS in the error. Throwaway __TEST_ organisation only.
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
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_brand uuid; v_model uuid; v_cust uuid; v_cust_t uuid; v_prod uuid; v_prod2 uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_vis1 uuid; v_vis2 uuid; v_vis3 uuid; v_vis4 uuid;
  v_r jsonb; v_r2 jsonb; v_credit uuid; v_credit_t uuid; n int; v_amt numeric; v_period date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
  v_inv_count int; v_rate uuid; rec record; v_msg text;
  fp_i text; fp_x text;
begin
  select md5(coalesce(string_agg(id::text||amount::text, ',' order by id), '')) into fp_i from public.incentives_earned
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select md5(coalesce(string_agg(id::text||coalesce(installation_charge::text,''), ',' order by id), '')) into fp_x from public.products
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  -- ---------- schema / ACL ----------
  perform pg_temp.chk('new columns exist', exists (select 1 from information_schema.columns where table_name='products' and column_name='installation_charge')
    and exists (select 1 from information_schema.columns where table_name='service_tickets' and column_name='installation_charge_snapshot')
    and exists (select 1 from information_schema.columns where table_name='incentives_earned' and column_name='credit_source'));
  perform pg_temp.chk('legacy 10-argument create_service_invoice is gone, exactly one overload remains',
    (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='create_service_invoice') = 1);
  perform pg_temp.chk('master RPCs: authenticated yes, anon no',
    has_function_privilege('authenticated','public.approve_installation_credit(uuid)','execute')
    and not has_function_privilege('anon','public.approve_installation_credit(uuid)','execute')
    and not has_function_privilege('anon','public.void_installation_credit(uuid,text)','execute')
    and not has_function_privilege('anon','public.set_ticket_installation_charge(uuid,numeric)','execute')
    and not has_function_privilege('authenticated','public._trg_installation_charge_snapshot()','execute'));
  perform pg_temp.chk('credits table: no direct write for authenticated/anon',
    not has_table_privilege('authenticated','public.installation_incentive_credits','insert')
    and not has_table_privilege('authenticated','public.installation_incentive_credits','update')
    and not has_table_privilege('anon','public.installation_incentive_credits','select'));

  -- ---------- throwaway org ----------
  insert into organizations (name) values ('__TEST_b17_installincentive') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Real-ish', '9400000011') returning id into v_cust;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ Flagged', '9400000012', true) returning id into v_cust_t;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price, installation_charge) values (v_org, '__TEST_ RO charge', 'ro', v_brand, v_model, 10000, 500) returning id into v_prod;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO nocharge', 'ro', v_brand, v_model, 9000) returning id into v_prod2;

  -- ---------- snapshot ----------
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_cust, v_prod, 'installation', 'Install 1') returning id into v_t1;
  perform pg_temp.chk('installation ticket snapshots the product charge', (select installation_charge_snapshot from service_tickets where id = v_t1) = 500);
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_cust, v_prod, 'paid', 'Repair') returning id into v_t2;
  perform pg_temp.chk('non-installation ticket has no snapshot', (select installation_charge_snapshot from service_tickets where id = v_t2) is null);
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_cust, v_prod2, 'installation', 'Install nocharge') returning id into v_t3;
  perform pg_temp.chk('product without a charge gives a NULL snapshot', (select installation_charge_snapshot from service_tickets where id = v_t3) is null);
  insert into service_tickets (org_id, customer_id, product_id, type, name_of_complaint) values (v_org, v_cust_t, v_prod, 'installation', 'Install flagged') returning id into v_t4;

  -- ---------- snapshot edit guards ----------
  perform pg_temp.as_user(v_sales);
  begin
    update service_tickets set installation_charge_snapshot = 9999 where id = v_t1;
  exception when others then
    null; -- refused by the guard trigger: also fine
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('non-master cannot change the snapshot directly (refused or no row visible)',
    (select installation_charge_snapshot from service_tickets where id = v_t1) = 500);
  perform pg_temp.as_user(v_sales);
  begin
    perform public.set_ticket_installation_charge(v_t1, 100);
    perform pg_temp.chk('non-master cannot call set_ticket_installation_charge', false);
  exception when others then
    perform pg_temp.chk('non-master cannot call set_ticket_installation_charge', sqlerrm like '%master role required%', sqlerrm);
  end;
  perform pg_temp.as_user(v_master);
  perform public.set_ticket_installation_charge(v_t1, 600);
  perform pg_temp.as_pg();
  perform pg_temp.chk('master can edit the snapshot before completion', (select installation_charge_snapshot from service_tickets where id = v_t1) = 600);
  perform pg_temp.as_user(v_master);
  begin
    perform public.set_ticket_installation_charge(v_t2, 100);
    perform pg_temp.chk('non-installation ticket rejected', false);
  exception when others then
    perform pg_temp.chk('non-installation ticket rejected', sqlerrm like '%only installation tickets%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ---------- completion creates a pending credit ----------
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t1, v_tech1) returning id into v_vis1;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_t1, 'always', v_tech1, 'in_progress');
  perform pg_temp.as_user(v_tp1);
  v_r := public.create_service_invoice(v_org, v_vis1, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0,
          jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 2)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('invoice created and ticket completed', (select status::text from service_tickets where id = v_t1) = 'completed' and v_r ->> 'invoice_id' is not null);
  select id into v_credit from installation_incentive_credits where ticket_id = v_t1;
  perform pg_temp.chk('one pending credit: 600 x 2 units = 1200',
    (select status = 'pending' and qty = 2 and unit_amount = 600 and amount = 1200 and technician_id = v_tech1 and product_id = v_prod from installation_incentive_credits where id = v_credit));
  perform pg_temp.chk('master was notified', exists (select 1 from notifications where org_id = v_org and type = 'installation_credit_pending' and ref_id = v_t1));

  -- replay = idempotent
  perform pg_temp.as_user(v_tp1);
  v_r2 := public.create_service_invoice(v_org, v_vis1, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0,
          jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 2)));
  perform pg_temp.as_pg();
  select count(*) into v_inv_count from invoices where org_id = v_org and customer_id = v_cust;
  perform pg_temp.chk('replay returns the same invoice and writes nothing', (v_r2 ->> 'invoice_id') = (v_r ->> 'invoice_id') and (v_r2 ->> 'already_completed') = 'true' and v_inv_count = 1);
  perform pg_temp.chk('still exactly one credit and one set of installation rows',
    (select count(*) from installation_incentive_credits where ticket_id = v_t1) = 1 and (select count(*) from installations_logged where visit_id = v_vis1) = 1);

  -- snapshot is frozen once completed
  perform pg_temp.as_user(v_master);
  begin
    perform public.set_ticket_installation_charge(v_t1, 1);
    perform pg_temp.chk('snapshot of a completed ticket cannot change', false);
  exception when others then
    perform pg_temp.chk('snapshot of a completed ticket cannot change', sqlerrm like '%closed ticket%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- a ticket with no charge gets no credit
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t3, v_tech1) returning id into v_vis3;
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(v_org, v_vis3, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0, '[]'::jsonb);
  perform pg_temp.as_pg();
  perform pg_temp.chk('no charge -> no credit', not exists (select 1 from installation_incentive_credits where ticket_id = v_t3));

  -- a non-installation ticket with a logged unit of the same product gets no credit (stays on the old rules)
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t2, v_tech1) returning id into v_vis2;
  perform pg_temp.as_user(v_tp1);
  perform public.create_service_invoice(v_org, v_vis2, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0,
          jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 1)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('non-installation ticket: no credit', not exists (select 1 from installation_incentive_credits where ticket_id = v_t2));

  -- ---------- visibility (RLS) ----------
  perform pg_temp.as_user(v_tp1);
  select count(*) into n from installation_incentive_credits;
  perform pg_temp.as_user(v_tp2);
  perform pg_temp.chk('technician sees only their own credit', n = 1 and (select count(*) from installation_incentive_credits) = 0, n::text);
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales staff cannot read credits', (select count(*) from installation_incentive_credits) = 0);
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('master sees all credits of the org', (select count(*) from installation_incentive_credits) = 1);
  perform pg_temp.as_pg();

  -- ---------- approval + compute ----------
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  perform pg_temp.chk('pending credit is NOT counted by Compute', not exists (select 1 from incentives_earned where org_id = v_org and credit_source is not null));
  perform pg_temp.as_user(v_sales);
  begin
    perform public.approve_installation_credit(v_credit);
    perform pg_temp.chk('non-master cannot approve', false);
  exception when others then
    perform pg_temp.chk('non-master cannot approve', sqlerrm like '%master role required%', sqlerrm);
  end;
  perform pg_temp.as_user(v_master);
  perform public.approve_installation_credit(v_credit);
  begin
    perform public.approve_installation_credit(v_credit);
    perform pg_temp.chk('approving twice is rejected', false);
  exception when others then
    perform pg_temp.chk('approving twice is rejected', sqlerrm like '%already approved%', sqlerrm);
  end;
  perform public.compute_incentives(v_org, v_period);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  select amount into v_amt from incentives_earned where org_id = v_org and credit_source = 'installation_ticket' and technician_id = v_tech1 and period = v_period;
  perform pg_temp.chk('approved credit counted once (Compute twice = same single row of 1200)', v_amt = 1200
    and (select count(*) from incentives_earned where org_id = v_org and credit_source is not null) = 1, coalesce(v_amt::text, 'null'));

  -- precedence: a per-unit rate for the same product does not pay the credited units again
  insert into installation_incentive_rates (org_id, product_id, flat_amount) values (v_org, v_prod, 300) returning id into v_rate;
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  perform pg_temp.chk('rate pays only the 1 uncredited unit (300), not the 2 credited ones',
    (select amount from incentives_earned where org_id = v_org and installation_rate_id = v_rate and technician_id = v_tech1) = 300);

  -- void: credit stops counting, and the unit falls back to the rate
  perform pg_temp.as_user(v_master);
  begin
    perform public.void_installation_credit(v_credit, '  ');
    perform pg_temp.chk('void needs a reason', false);
  exception when others then
    perform pg_temp.chk('void needs a reason', sqlerrm like '%reason is required%', sqlerrm);
  end;
  perform public.void_installation_credit(v_credit, 'test void');
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  select amount into v_amt from incentives_earned where org_id = v_org and credit_source = 'installation_ticket' and technician_id = v_tech1 and period = v_period;
  perform pg_temp.chk('voided credit: the credit row recomputes to 0', coalesce(v_amt, 0) = 0, coalesce(v_amt::text, 'null'));
  perform pg_temp.chk('voided credit: its 2 units fall back to the rate (3 units x 300 = 900)',
    (select amount from incentives_earned where org_id = v_org and installation_rate_id = v_rate and technician_id = v_tech1) = 900);

  -- ---------- test-customer flag: flagged ticket credit is never counted ----------
  insert into service_visits (org_id, ticket_id, technician_id) values (v_org, v_t4, v_tech2) returning id into v_vis4;
  perform pg_temp.as_user(v_tp2);
  perform public.create_service_invoice(v_org, v_vis4, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0, '[]'::jsonb);
  perform pg_temp.as_pg();
  select id into v_credit_t from installation_incentive_credits where ticket_id = v_t4;
  perform pg_temp.chk('flagged customer ticket still gets a credit row', v_credit_t is not null);
  perform pg_temp.as_user(v_master);
  perform public.approve_installation_credit(v_credit_t);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  perform pg_temp.chk('...but Compute ignores it (test customer)', not exists (select 1 from incentives_earned where org_id = v_org and technician_id = v_tech2 and credit_source is not null and amount > 0));

  -- ---------- other roles cannot complete someone else's visit (existing guard unchanged) ----------
  perform pg_temp.as_user(v_tp2);
  begin
    perform public.create_service_invoice(v_org, v_vis2, 0, 0, '[]'::jsonb, 'cash', null, null, false, 0, '[]'::jsonb);
    perform pg_temp.chk('another technician cannot complete this visit', false);
  exception when others then
    perform pg_temp.chk('another technician cannot complete this visit', true, sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ---------- real data unchanged ----------
  perform pg_temp.chk('real incentives_earned unchanged', fp_i = (select md5(coalesce(string_agg(id::text||amount::text, ',' order by id), '')) from public.incentives_earned
    where org_id not in (select id from organizations where name like '\_\_TEST\_%')));
  perform pg_temp.chk('real products unchanged (installation_charge still NULL everywhere)', fp_x = (select md5(coalesce(string_agg(id::text||coalesce(installation_charge::text,''), ',' order by id), '')) from public.products
    where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
