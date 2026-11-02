-- Rolled-back DB tests for 20261201110000_lead_edit_details (Edit Lead screen).
-- One transaction ending in RAISE; read RESULTS in the error. NOT run as part of this
-- task -- the migration itself is unapplied; this file is rehearsed alongside it via
-- _local_only/reports/run_rehearsal.mjs, not executed directly by an agent.
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
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__T ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; v_ops uuid; v_tech uuid; v_cust uuid; b boolean;
  l1 uuid; l2 uuid; l_ref uuid; v_row public.leads;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  v_master := pg_temp.mkuser('master', v_org); v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org); v_tech := pg_temp.mkuser('technician', v_org); v_cust := pg_temp.mkuser('customer', v_org);

  insert into leads(org_id,name,mobile,source) values (v_org,'__T_edit1','9555555601','walk_in') returning id into l1;
  insert into leads(org_id,name,mobile,source,owner_id) values (v_org,'__T_edit2','9555555602','referral',v_tech) returning id into l_ref;

  -- ===== role gate: master/sales_admin/operation_admin allowed, technician/customer not =====
  perform pg_temp.as_user(v_sales);
  perform public.update_lead_details(l1, 'Sales Edited', '9555555611', null, 'Door 1, Street X', 'whatsapp', null, 'note A');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin can edit', (select name from leads where id=l1)='Sales Edited');

  perform pg_temp.as_user(v_ops);
  perform public.update_lead_details(l1, 'Ops Edited', '9555555612', '9555555699', 'Door 2', 'walk_in', null, 'note B');
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin can edit (task requirement)', (select name from leads where id=l1)='Ops Edited');
  perform pg_temp.chk('alternate_mobile saved', (select alternate_mobile from leads where id=l1)='9555555699');
  perform pg_temp.chk('address_text saved', (select address_text from leads where id=l1)='Door 2');

  perform pg_temp.as_user(v_tech);
  begin perform public.update_lead_details(l1, 'Tech Edited', '9555555613', null, null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('technician cannot edit', b=false);

  perform pg_temp.as_user(v_cust);
  begin perform public.update_lead_details(l1, 'Cust Edited', '9555555614', null, null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('customer cannot edit', b=false);

  -- ===== validation =====
  perform pg_temp.as_user(v_master);
  begin perform public.update_lead_details(l1, '   ', '9555555615', null, null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('blank name rejected', b=false);
  begin perform public.update_lead_details(l1, 'Ok Name', '12345', null, null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('invalid mobile rejected', b=false);
  begin perform public.update_lead_details(l1, 'Ok Name', '9555555615', '555', null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('invalid alternate mobile rejected', b=false);
  begin perform public.update_lead_details(l1, 'Ok Name', '9555555615', null, null, 'not_a_real_source_key', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('unknown source key rejected', b=false);
  perform pg_temp.as_pg();

  -- ===== CRITICAL: owner_id is never a parameter / never moves =====
  update leads set owner_id = v_tech where id = l1;
  perform pg_temp.as_user(v_master);
  perform public.update_lead_details(l1, 'Owner Untouched', '9555555616', null, null, 'walk_in', null, null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('owner_id untouched by an unrelated edit', (select owner_id from leads where id=l1)=v_tech);

  -- ===== CRITICAL: referral source immutable in both directions =====
  perform pg_temp.as_user(v_master);
  begin perform public.update_lead_details(l_ref, 'Ref Edited', '9555555602', null, null, 'walk_in', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('cannot flip existing referral lead away from referral', b=false);
  perform pg_temp.chk('referral lead source unchanged after rejected attempt', (select source from leads where id=l_ref)='referral');

  begin perform public.update_lead_details(l1, 'L1', '9555555616', null, null, 'referral', null, null); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('cannot manually set source to referral on a non-referral lead', b=false);

  -- non-referral source change (allowed) + non-change of referral to itself (allowed, no-op)
  perform public.update_lead_details(l1, 'L1', '9555555616', null, null, 'other', null, null);
  perform pg_temp.chk('non-referral source change allowed', (select source from leads where id=l1)='other');
  perform public.update_lead_details(l_ref, 'Ref Edited Name Only', '9555555602', null, null, 'referral', null, null);
  perform pg_temp.chk('keeping source=referral unchanged is allowed', (select source from leads where id=l_ref)='referral');
  perform pg_temp.as_pg();

  -- ===== audit_log row per edit =====
  perform pg_temp.chk('audit_log has rows for these edits',
    (select count(*) from audit_log where table_name='leads' and row_id in (l1, l_ref)) >= 5);
  select * into v_row from leads where id = l1;
  perform pg_temp.chk('audit before/after captures tracked fields',
    (select (after->>'source') from audit_log where table_name='leads' and row_id=l1 order by created_at desc limit 1) = v_row.source);

  raise exception 'RESULTS: %', (select string_agg(line, E'\n' order by n) from res);
end $t$;
