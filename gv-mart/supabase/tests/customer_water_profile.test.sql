-- Rolled-back DB tests for migration 20261108100000_customer_water_profile. One transaction
-- ending in RAISE; read RESULTS in the error. Uses throwaway __TEST_ organisations created
-- inside the transaction only, so nothing persists and no real customer row is read or written.
--
-- A refusal that RLS turns into "0 rows affected" (no policy matches the role at all) is
-- asserted with GET DIAGNOSTICS row_count, not by wrapping in begin/exception — an UPDATE
-- that simply matches zero rows under RLS does not raise anything, so exception-catching
-- there would silently pass even if the write actually went through. A refusal that is a real
-- RAISE (our own trigger, the pre-existing guard_customer_self_update trigger, or an INSERT's
-- WITH CHECK failing outright) is still asserted with exception-catching, since those really
-- do raise.
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
  v_cust uuid; v_fp_before bigint; v_fp_after bigint;
  v_tech uuid; v_tech2 uuid; v_tk uuid; v_appt uuid; v_other_org_staff uuid;
  b boolean; txt text; v_rows bigint;
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

  select count(*) into v_fp_before from public.customers where org_id <> v_org and org_id <> v_org2;

  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ water profile job') returning id into v_tk;
  insert into appointments (org_id, ticket_id, mode, technician_id, status) values (v_org, v_tk, 'always', v_tech, 'in_progress') returning id into v_appt;

  v_other_org_staff := pg_temp.mkuser('master', v_org2);

  -- ══ WATER FIELDS ON customers ══════════════════════════════════════════════════════════

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

  begin update customers set water_ph = -0.1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH of -0.1 refused', b = false);
  begin update customers set water_ph = 14.1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('pH of 14.1 refused', b = false);
  begin update customers set water_ph = 0 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 0 accepted', b);
  begin update customers set water_ph = 14 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('pH of 14 accepted', b);
  update customers set water_ph = 6.5 where id = v_cust;

  begin update customers set water_tds_ppm = -1 where id = v_cust; b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('TDS below 0 refused', b = false);
  begin update customers set water_tds_ppm = 570 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('TDS of 570 accepted', b);
  perform pg_temp.as_pg();

  -- role write access: master, operation_admin AND sales_admin (per the spec) can set the
  -- water columns; customer and technician cannot.
  perform pg_temp.as_user(v_master);
  begin update customers set water_tds_ppm = 300 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('master can set the water fields', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customers set water_tds_ppm = 310, water_ph = 7, water_source = 'borewater' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can set the water fields', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customers set water_tds_ppm = 330, water_ph = 7.2 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin can set the water fields (per the spec)', b);
  begin update customers set notes = '__TEST_ sales admin note' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin still has its existing write access to an unrelated column', b);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  begin update customers set water_tds_ppm = 340 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a customer cannot set the water fields on their own row (guard_customer_self_update raises)', b = false);
  perform pg_temp.as_pg();

  -- technician: no write policy at all on customers, so this is a real 0-row RLS filter, not
  -- an exception — asserted with GET DIAGNOSTICS, not begin/exception.
  perform pg_temp.as_user(v_techprofile);
  update customers set water_tds_ppm = 350 where id = v_cust;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('a technician updates ZERO rows on customers (no write policy at all)', v_rows = 0);
  perform pg_temp.as_pg();

  update customers set water_source = 'borewater', water_source_other = null, water_tds_ppm = 570, water_ph = 6.5 where id = v_cust;

  -- ══ operation_admin is trigger-restricted to ONLY the water columns ══════════════════════
  -- (master and sales_admin are NOT restricted by this trigger — they already have full
  -- customers write access through other means, per the design note in the migration.)
  perform pg_temp.as_user(v_opadmin);
  begin update customers set water_tds_ppm = 360, notes = 'operation_admin snuck a note in' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin is refused when the same statement also touches notes', b = false);
  begin update customers set mobile = '9000000399' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin changing mobile alone is refused', b = false);
  begin update customers set name = '__TEST_ renamed by op admin' where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin changing name alone is refused', b = false);
  begin update customers set primary_profile_id = null where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin changing primary_profile_id alone is refused', b = false);
  begin update customers set is_test = true where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin changing is_test alone is refused', b = false);
  begin update customers set org_id = v_org2 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin changing org_id alone is refused', b = false);
  -- confirm none of the refused attempts above actually stuck, and a water-only update still works
  perform pg_temp.chk('customer row is unaffected by any of the refused operation_admin attempts',
    (select mobile from customers where id = v_cust) = '9000000301'
    and (select name from customers where id = v_cust) <> '__TEST_ renamed by op admin'
    and (select primary_profile_id from customers where id = v_cust) = v_custprofile
    and (select is_test from customers where id = v_cust) = false
    and (select org_id from customers where id = v_cust) = v_org);
  begin update customers set water_tds_ppm = 365 where id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('a water-only update by operation_admin still succeeds', b);
  perform pg_temp.as_pg();

  update customers set water_tds_ppm = 570 where id = v_cust;

  -- reads: a customer reads only their own profile; another org's staff read nothing
  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer can read their own water_tds_ppm', (select water_tds_ppm from customers where id = v_cust) = 570);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_other_org_staff);
  perform pg_temp.chk('another organisation''s staff read zero customers rows for this customer', (select count(*) from customers where id = v_cust) = 0);
  perform pg_temp.as_pg();

  perform pg_temp.chk('no family-member count column was added to customers',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name in ('family_members','family_size','members_count')));
  perform pg_temp.chk('ro_checklists.water_tds_ppm column is unchanged by this migration',
    (select data_type from information_schema.columns where table_schema='public' and table_name='ro_checklists' and column_name='water_tds_ppm') = 'numeric');
  perform pg_temp.chk('health_condition is NOT a column on customers (lives in its own table)',
    not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='health_condition'));

  -- ACL: anon has no privileges on customer_health_profile at all, and cannot execute the
  -- technician-path function either.
  perform pg_temp.chk('anon has no select/insert/update privilege on customer_health_profile',
    not has_table_privilege('anon', 'public.customer_health_profile', 'select')
    and not has_table_privilege('anon', 'public.customer_health_profile', 'insert')
    and not has_table_privilege('anon', 'public.customer_health_profile', 'update'));
  perform pg_temp.chk('anon cannot execute get_customer_health_condition',
    not has_function_privilege('anon', 'public.get_customer_health_condition(uuid)', 'execute'));

  -- ══ cross-org planting, BEFORE any customer_health_profile row exists for v_cust ═════════
  -- org2 staff tries to insert a health row for v_org's customer while claiming org_id =
  -- v_org2 (their own org) — the WITH CHECK's exists() integrity check must refuse this even
  -- though org_id = current_org_id() and is_staff() both pass on their own.
  perform pg_temp.as_user(v_other_org_staff);
  begin
    insert into customer_health_profile (customer_id, org_id, health_condition) values (v_cust, v_org2, 'high');
    b := true;
  exception when others then b := false; end;
  perform pg_temp.chk('cross-org planting: org2 staff cannot insert a health row for org1''s customer', b = false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the planting attempt left no row behind', not exists (select 1 from customer_health_profile where customer_id = v_cust));

  -- ══ customer_health_profile (its own table) ═══════════════════════════════════════════

  perform pg_temp.as_user(v_master);
  begin
    insert into customer_health_profile (customer_id, org_id, health_condition) values (v_cust, v_org, 'high');
    b := true;
  exception when others then b := false; end;
  perform pg_temp.chk('master can insert a health_condition row', b);
  perform pg_temp.chk('updated_by is stamped from auth.uid(), not client-supplied', (select updated_by from customer_health_profile where customer_id = v_cust) = v_master);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_opadmin);
  begin update customer_health_profile set health_condition = 'medium' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('operation_admin can update health_condition', b and (select updated_by from customer_health_profile where customer_id = v_cust) = v_opadmin);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_salesadmin);
  begin update customer_health_profile set health_condition = 'medium' where customer_id = v_cust; b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales_admin can update health_condition (is_staff())', b);
  perform pg_temp.as_pg();

  -- customer and technician: no insert/update policy at all on this table, so an UPDATE is a
  -- real 0-row RLS filter, not an exception.
  perform pg_temp.as_user(v_custprofile);
  update customer_health_profile set health_condition = 'none' where customer_id = v_cust;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('a customer updates ZERO rows on their own customer_health_profile row (no write policy)', v_rows = 0);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  update customer_health_profile set health_condition = 'none' where customer_id = v_cust;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('a technician updates ZERO rows on customer_health_profile (no table access at all)', v_rows = 0);
  perform pg_temp.as_pg();

  -- health_condition enum itself refuses an out-of-range value
  begin execute format('insert into customer_health_profile (customer_id, org_id, health_condition) values (%L, %L, %L)', gen_random_uuid(), v_org, 'critical'); b := true; exception when invalid_text_representation then b := false; end;
  perform pg_temp.chk('health_condition enum refuses a value outside the 4 levels', b = false);

  update customer_health_profile set health_condition = 'medium' where customer_id = v_cust;

  -- direct-table reads: staff yes; the customer their own row; a technician NEVER; another
  -- org's staff read nothing
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff reads the row directly from customer_health_profile', (select health_condition from customer_health_profile where customer_id = v_cust) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer reads their own customer_health_profile row directly', (select health_condition from customer_health_profile where customer_id = v_cust) = 'medium');
  perform pg_temp.chk('the customer reads NO ONE ELSE''S customer_health_profile row', (select count(*) from customer_health_profile where customer_id <> v_cust) = 0);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_other_org_staff);
  perform pg_temp.chk('another organisation''s staff read zero customer_health_profile rows for this customer', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('a technician reads ZERO rows directly from customer_health_profile (setting off)', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.as_pg();

  -- get_customer_health_condition: the function path
  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician cannot read health via the function either while the setting is off', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_other_org_staff);
  perform pg_temp.chk('get_customer_health_condition returns null for another organisation''s staff', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  -- org creation does not create a settings row — insert one before flipping the switch.
  insert into settings (org_id) values (v_org);
  update settings set show_health_condition_to_technicians = true where org_id = v_org;
  get diagnostics v_rows = row_count;
  perform pg_temp.chk('show_health_condition_to_technicians update affects exactly 1 row', v_rows = 1);

  perform pg_temp.as_user(v_techprofile);
  perform pg_temp.chk('technician reads ZERO rows directly even with the setting ON (no table policy exists for them)', (select count(*) from customer_health_profile where customer_id = v_cust) = 0);
  perform pg_temp.chk('technician reads the level via the function ONLY, once the setting is on and they have an appointment', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_techprofile2);
  perform pg_temp.chk('a different technician with no appointment for this customer still gets nothing from the function', (select public.get_customer_health_condition(v_cust)) is null);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('staff gets the level from the function too', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_custprofile);
  perform pg_temp.chk('the customer gets their own level from the function too', (select public.get_customer_health_condition(v_cust)) = 'medium');
  perform pg_temp.as_pg();

  -- fingerprint: a real org's customers are unchanged by this migration
  select count(*) into v_fp_after from public.customers where org_id <> v_org and org_id <> v_org2;
  perform pg_temp.chk('a real organisation''s customer row count is unchanged by the migration', v_fp_after = v_fp_before);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
