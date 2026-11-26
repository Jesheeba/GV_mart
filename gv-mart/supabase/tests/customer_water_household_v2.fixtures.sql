-- Pre-migration fixtures for customer_water_household_v2.test.sql. Runs BEFORE 20261215100000 inside the same
-- rolled-back rehearsal transaction, so the address-to-customer backfill can be asserted on known rows. Throwaway
-- __TEST_ organisation only; ids are kept in pg_temp.fx for the test block.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create temp table fx (k text primary key, v uuid);
grant all on fx to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.fx(p_k text) returns uuid language sql as $f$ select v from pg_temp.fx where k = p_k $f$;
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

do $fx$
declare
  v_org uuid; v_org2 uuid; v uuid;
begin
  insert into organizations (name) values ('__TEST_water_v2_org') returning id into v_org;
  insert into organizations (name) values ('__TEST_water_v2_org2') returning id into v_org2;
  insert into pg_temp.fx values ('org', v_org), ('org2', v_org2);
  -- the real-org baseline is taken before anything else so the test can show the backfill touched only expected rows
  insert into pg_temp.fx values ('master', pg_temp.mkuser('master', v_org));
  insert into pg_temp.fx values ('master_late', pg_temp.mkuser('master', v_org));
  insert into pg_temp.fx values ('sales', pg_temp.mkuser('sales_admin', v_org));
  insert into pg_temp.fx values ('sales2', pg_temp.mkuser('sales_admin', v_org));
  insert into pg_temp.fx values ('opadmin', pg_temp.mkuser('operation_admin', v_org));
  insert into pg_temp.fx values ('tech', pg_temp.mkuser('technician', v_org));
  insert into pg_temp.fx values ('custp', pg_temp.mkuser('customer', v_org));
  insert into pg_temp.fx values ('other_master', pg_temp.mkuser('master', v_org2));
  insert into technicians (org_id, profile_id, is_active) values (v_org, pg_temp.fx('tech'), true);
  -- the second master is newer: the follow-up task must go to the OLDEST active master
  update public.profiles set created_at = now() - interval '10 days' where id = pg_temp.fx('master');

  -- backfill cases (address water columns still exist at this point)
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 corp', '9000000401') returning id into v;
  insert into pg_temp.fx values ('c_corp', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_source, water_tds, water_ph, health_condition)
    values (v_org, v, '__TEST_ addr 1', true, '  Corporation ', 300, 7.2, 'Kidney stones');

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 bore', '9000000402') returning id into v;
  insert into pg_temp.fx values ('c_bore', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_source)
    values (v_org, v, '__TEST_ addr 2', true, 'Bore well');

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 lake', '9000000403') returning id into v;
  insert into pg_temp.fx values ('c_lake', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_source, health_condition)
    values (v_org, v, '__TEST_ addr 3', true, 'Lake water', '   ');

  -- customer already has its own values: the address copy must NOT overwrite them
  insert into customers (org_id, name, mobile, water_source, water_tds_ppm) values (v_org, '__TEST_ wv2 keep', '9000000404', 'corporation', 100) returning id into v;
  insert into pg_temp.fx values ('c_keep', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_source, water_tds, water_ph)
    values (v_org, v, '__TEST_ addr 4', true, 'Lake', 999, 6.5);

  -- out-of-range numbers are skipped, not fatal
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 range', '9000000405') returning id into v;
  insert into pg_temp.fx values ('c_range', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_tds, water_ph)
    values (v_org, v, '__TEST_ addr 5', true, 20000, 15);

  -- non-primary address with data and a primary without: the primary is the one used (here: nothing)
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 primary', '9000000406') returning id into v;
  insert into pg_temp.fx values ('c_primary', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_tds) values (v_org, v, '__TEST_ addr 6a', true, 50);
  insert into addresses (org_id, customer_id, full_address, is_primary, water_tds) values (v_org, v, '__TEST_ addr 6b', false, 777);

  -- a plain customer for the follow-up tests, with the customer login linked
  insert into customers (org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_ wv2 followup', '9000000407', pg_temp.fx('custp')) returning id into v;
  insert into pg_temp.fx values ('c_fu', v);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ wv2 other', '9000000408') returning id into v;
  insert into pg_temp.fx values ('c_other', v);
  insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ wv2 org2 cust', '9000000409') returning id into v;
  insert into pg_temp.fx values ('c_org2', v);

  -- a health row, to prove the table really goes
  insert into customer_health_profile (customer_id, org_id, health_condition) values (pg_temp.fx('c_fu'), v_org, 'high');

  -- real-organisation snapshot (every column), compared after the migrations
  create temp table real_before as
    select c.id, to_jsonb(c) as j from public.customers c where c.org_id not in (v_org, v_org2);
end $fx$;
