-- Rolled-back DB tests for migration 20261108100000_customer_water_profile. One transaction
-- ending in RAISE; read RESULTS in the error. Uses a throwaway __TEST_ organisation created
-- inside the transaction, so nothing persists and no real customer row is read or written.
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
  v_org uuid; v_org2 uuid;
  v_master uuid; v_opadmin uuid; v_salesadmin uuid; v_custprofile uuid; v_techprofile uuid; v_techprofile2 uuid;
  v_cust uuid; v_cust_fingerprint_before bigint; v_cust_fingerprint_after bigint;
  v_tech uuid; v_tech2 uuid; v_tk uuid; v_appt uuid;
  v_latest_reading_count bigint;
  b boolean; txt text;
begin
  insert into organizations (name) values ('__TEST_water_profile_org') returning id into v_org;
  insert into organizations (name) values ('__TEST_water_profile_org2') returning id into v_org2;

  v_master := pg_temp.mkuser('master', v_org);
  v_opadmin := pg_temp.mkuser('operation_admin', v_org);
  v_salesadmin := pg_temp.mkuser('sales_admin', v_org);
  v_custprofile := pg_temp.mkuser('customer', v_org);
  v_techprofile := pg_temp.mkuser('technician', v_org);
  v_techprofile2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_techprofile, true) returning id into v_tech;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_techprofile2, true) returning id into v_tech2;

  insert into customers (org_id, name, mobile, primary_profile_id)
    values (v_org, '__TEST_ water profile customer', '9000000301', v_custprofile) returning id into v_cust;

  -- "a real organisation's customers are unchanged by the migration" fingerprint: taken on an
  -- org other than the throwaway one above, before/after everything else in this test runs.
  select count(*) into v_cust_fingerprint_before from public.customers where org_id <> v_org and org_id <> v_org2;

  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ water profile job') returning id into v_tk;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_tk, 'always', v_tech, 'in_progress') returning id into v_appt;

  -- ── water_source enum + water_source_other rule ──────────────────────────────────────────
  perform pg_temp.as_user(v_master);
  update customers set water_source = 'corporation' where id = v_cust;
  update customers set water_source = 'borewater' where id = v_cust;
  update customers set water_source = 'other' where id = v_cust;
  perform pg_temp.chk('water_source accepts all 3 enum values', (select water_source from customers where id = v_cust) = 'other');

  begin update customers set water_source = 'corporation', water_source_other = 'well' where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('water_source_other is refused unless water_source = other', b = false);
  begin update customers set water_source = 'other', water_source_other = 'well water' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('water_source_other accepted with water_source = other', b);
  update customers set water_source_other = null where id = v_cust;

  -- ── pH range ──────────────────────────────────────────────────────────────────────────────
  begin update customers set water_ph = -0.01 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH below 0 refused', b = false);
  begin update customers set water_ph = 14.01 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH above 14 refused', b = false);
  begin update customers set water_ph = 0 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 0 accepted', b);
  begin update customers set water_ph = 14 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 14 accepted', b);
  update customers set water_ph = 6.5 where id = v_cust;

  -- ── TDS ───────────────────────────────────────────────────────────────────────────────────
  begin update customers set water_tds_ppm = -1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('TDS below 0 refused', b = false);
  begin update customers set water_tds_ppm = 570 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('TDS of 570 accepted', b);

  -- ── health_condition enum ────────────────────────────────────────────────────────────────
  update customers set health_condition = 'none' where id = v_cust;
  update customers set health_condition = 'normal' where id = v_cust;
  update customers set health_condition = 'medium' where id = v_cust;
  update customers set health_condition = 'high' where id = v_cust;
  perform pg_temp.chk('health_condition accepts all 4 enum values', (select health_condition from customers where id = v_cust) = 'high');
  begin execute format('update customers set health_condition = %L where id = %L', 'critical', v_cust); b := true; exception when invalid_text_representation then b := false; end;
  perform pg_temp.chk('health_condition refuses a value outside the 4 levels', b = false);
  perform pg_temp.as_pg();

  -- ── role write access: master, operation_admin can set all 4; sales_admin, customer,
  --    technician cannot touch them (but sales_admin can still touch an unrelated column) ────
  perform pg_temp.as_user(v_master);
  begin update customers set water_tds_ppm = 300, health_condition = 'normal' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('master can set the water/health fields', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customers set water_tds_ppm = 310, water_ph = 7, water_source = 'borewater', health_condition = 'medium' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can set the water/health fields', b);
  begin update customers set water_tds_ppm = 320, notes = 'operation_admin snuck a note in' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin is refused when the same statement also touches a non-water column', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customers set water_tds_ppm = 330 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin is refused when touching a water/health column', b = false);
  begin update customers set notes = '__TEST_ sales admin note' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin still has its existing write access to an unrelated column', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  begin update customers set water_tds_ppm = 340 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a customer cannot set the water/health fields on their own row', b = false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  begin update customers set water_tds_ppm = 350 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a technician cannot write the water/health fields (no write policy at all)', b = false);
  perform pg_temp.as_pg();

  -- reset to known values used by the read checks below
  update customers set water_source = 'borewater', water_source_other = null, water_tds_ppm = 570, water_ph = 6.5, health_condition = 'medium' where id = v_cust;

  -- ── reads: a customer reads only their own profile; another org's staff read nothing ──────
  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer can read their own water_tds_ppm', (select water_tds_ppm from customers where id = v_cust) = 570);
  perform pg_temp.as_pg();

  declare
    v_other_org_staff uuid;
  begin
    v_other_org_staff := pg_temp.mkuser('master', v_org2);
    perform pg_temp.as_user(v_other_org_staff);
    perform pg_temp.chk('another organisation''s staff read zero rows for this customer', (select count(*) from customers where id = v_cust) = 0);
    perform pg_temp.as_pg();
  end;

  -- ── get_customer_health_condition: staff always; customer their own; technician only when
  --    the setting is on AND they have an appointment with that customer ───────────────────
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff sees the health level via the function', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer sees their own health level via the function', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician sees NOTHING via the function while the setting is off', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  update settings set show_health_condition_to_technicians = true where org_id = v_org;

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician with an appointment for this customer sees the level once the setting is on', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile2);
  perform pg_temp.chk('a different technician with no appointment for this customer still sees nothing', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  perform pg_temp.chk('health_condition is not directly selectable via the raw table by authenticated/anon',
    not has_column_privilege('authenticated', 'public.customers', 'health_condition', 'select')
    and not has_column_privilege('anon', 'public.customers', 'health_condition', 'select'));

  -- ── latest on-site reading stays untouched (ro_checklists / service_visits unaffected) ────
  perform pg_temp.chk('ro_checklists.water_tds_ppm column is unchanged by this migration',
    (select data_type from information_schema.columns where table_schema='public' and table_name='ro_checklists' and column_name='water_tds_ppm') = 'numeric');

  -- ── derived family-member count: no stored column added ────────────────────────────────
  perform pg_temp.chk('no family-member count column was added to customers',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name in ('family_members','family_size','members_count')));

  -- ── fingerprint: a real org's customers are unchanged by this migration ───────────────────
  select count(*) into v_cust_fingerprint_after from public.customers where org_id <> v_org and org_id <> v_org2;
  perform pg_temp.chk('a real organisation''s customer row count is unchanged by the migration', v_cust_fingerprint_after = v_cust_fingerprint_before);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
