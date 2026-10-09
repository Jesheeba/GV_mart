-- Rolled-back DB tests for migration 20261012100000_lead_kinds_and_product_types (batch-17 items 2 and 4).
-- Runs inside ONE transaction that ends in RAISE; read RESULTS in the error. Uses a throwaway __TEST_ organisation
-- created inside the transaction, so nothing persists and no real client row is read or written.
-- Optional: if a temp table pre_fp(id, updated_at) exists (captured BEFORE the migration), it also checks the backfill left updated_at untouched.
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
  v_org uuid; v_org2 uuid; v_master uuid; v_sales uuid; txt text; b boolean; n int; rec record;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; lk uuid; pt uuid; k text; pc text; kk text;
begin
  insert into organizations (name) values ('__TEST_b17_lists') returning id into v_org;
  insert into organizations (name) values ('__TEST_b17_other') returning id into v_org2;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);

  -- seeds -------------------------------------------------------------------------------------------
  perform pg_temp.chk('new org seeds 5 kinds (4 system + warranty)', (select count(*) from lead_kinds where org_id=v_org)=5 and (select count(*) from lead_kinds where org_id=v_org and is_system)=4);
  perform pg_temp.chk('warranty kind is a deletable (non-system) row', (select is_system from lead_kinds where org_id=v_org and key='warranty') = false);
  perform pg_temp.chk('new org seeds 5 product types (4 system + multigrade)', (select count(*) from lead_product_types where org_id=v_org)=5 and (select count(*) from lead_product_types where org_id=v_org and is_system)=4);
  perform pg_temp.chk('system kinds are service/spare/product/amc', (select array_agg(key order by key) from lead_kinds where org_id=v_org and is_system) = array['amc','product','service','spare']);
  perform pg_temp.chk('system types are ac/battery/inverter/ro', (select array_agg(key order by key) from lead_product_types where org_id=v_org and is_system) = array['ac','battery','inverter','ro']);
  perform pg_temp.chk('every existing real org got the seeds', not exists (select 1 from organizations o where o.id not in (v_org, v_org2) and ((select count(*) from lead_kinds k where k.org_id=o.id) < 5 or (select count(*) from lead_product_types p where p.org_id=o.id) < 5)));

  -- RLS ---------------------------------------------------------------------------------------------------
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin can read the lists', (select count(*) from lead_kinds)=5 and (select count(*) from lead_product_types)=5);
  begin insert into lead_kinds (org_id,key,label) values (v_org,'x_sales','X'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('sales_admin cannot add a kind', b=false);
  begin insert into lead_product_types (org_id,key,label) values (v_org,'x_sales','X'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('sales_admin cannot add a product type', b=false);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(v_master);
  insert into lead_kinds (org_id,key,label,label_ta) values (v_org,'installation','Installation','நிறுவல்') returning id into lk;
  insert into lead_product_types (org_id,key,label) values (v_org,'water_heater','Water heater') returning id into pt;
  perform pg_temp.chk('master can add a kind and a product type', lk is not null and pt is not null);
  perform pg_temp.chk('master sees only own org rows', (select count(*) from lead_kinds)=6);
  perform pg_temp.chk('audit rows written for list changes', (select count(*) from audit_log where table_name in ('lead_kinds','lead_product_types') and org_id=v_org) >= 2);
  perform pg_temp.as_pg();

  -- guards ----------------------------------------------------------------------------------------------
  perform pg_temp.as_user(v_master);
  begin delete from lead_kinds where org_id=v_org and key='service'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
  perform pg_temp.chk('system kind cannot be deleted', b=false);
  begin delete from lead_product_types where org_id=v_org and key='ro'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
  perform pg_temp.chk('system product type cannot be deleted', b=false);
  begin update lead_kinds set key='renamed' where id=lk; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('key cannot be changed', b=false);
  begin update lead_kinds set is_system=true where id=lk; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('is_system cannot be flipped', b=false);
  update lead_kinds set label='Installation work', is_active=false where id=lk;
  perform pg_temp.chk('label rename and deactivate allowed', (select label='Installation work' and not is_active from lead_kinds where id=lk));
  update lead_kinds set is_active=true where id=lk;
  begin update lead_kinds set label='Service!' where org_id=v_org and key='service'; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('system row label can still be edited', b);
  perform pg_temp.as_pg();

  -- leads dual-write ------------------------------------------------------------------------------------
  insert into leads (org_id,name,mobile,kind) values (v_org,'__TEST_a','9000000001','spare') returning id into l1;
  select kind_key, product_type_key into kk, pc from leads where id=l1;
  perform pg_temp.chk('old writer: kind enum fills kind_key', kk='spare');
  insert into leads (org_id,name,mobile,product_category) values (v_org,'__TEST_b','9000000002','inverter') returning id into l2;
  perform pg_temp.chk('old writer: product_category fills product_type_key', (select product_type_key from leads where id=l2)='inverter');
  insert into leads (org_id,name,mobile,kind_key,product_type_key) values (v_org,'__TEST_c','9000000003','amc','battery') returning id into l3;
  perform pg_temp.chk('new writer: kind_key fills kind enum', (select kind::text from leads where id=l3)='amc');
  perform pg_temp.chk('new writer: product_type_key fills product_category enum', (select product_category::text from leads where id=l3)='battery');
  insert into leads (org_id,name,mobile,kind_key,product_type_key) values (v_org,'__TEST_d','9000000004','warranty','multigrade') returning id into l4;
  select kind::text, kind_key, product_category::text, product_type_key into k, kk, pc, txt from leads where id=l4;
  perform pg_temp.chk('custom keys stored; old enum columns stay null', k is null and kk='warranty' and pc is null and txt='multigrade', coalesce(k,'null')||'/'||kk||'/'||coalesce(pc,'null')||'/'||txt);
  begin insert into leads (org_id,name,mobile,kind_key) values (v_org,'__TEST_bad','9000000005','nope'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('unknown kind key rejected', b=false);
  begin insert into leads (org_id,name,mobile,product_type_key) values (v_org,'__TEST_bad','9000000005','nope'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('unknown product type key rejected', b=false);
  begin insert into leads (org_id,name,mobile,kind_key) values (v_org2,'__TEST_bad','9000000005','installation'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('a key from ANOTHER org is rejected', b=false);
  update leads set kind='product' where id=l1;
  perform pg_temp.chk('update enum -> kind_key follows', (select kind_key from leads where id=l1)='product');
  update leads set kind_key='service' where id=l1;
  perform pg_temp.chk('update kind_key -> enum follows', (select kind::text from leads where id=l1)='service');
  update leads set kind_key='warranty' where id=l1;
  perform pg_temp.chk('moving to a custom key keeps the key', (select kind_key from leads where id=l1)='warranty');
  update leads set kind_key=null where id=l1;
  perform pg_temp.chk('clearing kind_key clears the enum', (select kind is null and kind_key is null from leads where id=l1));
  insert into leads (org_id,name,mobile,kind_key) values (v_org,'__TEST_e','9000000006','installation') returning id into l5;
  begin delete from lead_kinds where id=lk; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
  perform pg_temp.chk('custom kind in use cannot be deleted', b=false);
  begin delete from lead_product_types where org_id=v_org and key='multigrade'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
  perform pg_temp.chk('custom product type in use cannot be deleted', b=false);
  delete from leads where id=l5;
  begin delete from lead_kinds where id=lk; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
  perform pg_temp.chk('custom kind not in use CAN be deleted', b);
  delete from lead_product_types where id=pt;
  perform pg_temp.chk('custom product type not in use CAN be deleted', not exists (select 1 from lead_product_types where id=pt));

  -- list functions ---------------------------------------------------------------------------------------
  perform pg_temp.chk('exactly one list_followups overload', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_followups')=1);
  perform pg_temp.chk('exactly one list_leads_without_followup overload', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_leads_without_followup')=1);
  perform pg_temp.chk('list functions: anon/public cannot execute, authenticated can',
    not has_function_privilege('anon','public.list_followups(text,public.lead_status,text,text,boolean,text,uuid)','execute')
    and has_function_privilege('authenticated','public.list_followups(text,public.lead_status,text,text,boolean,text,uuid)','execute')
    and not has_function_privilege('anon','public.list_leads_without_followup(public.lead_status,text,text,text,uuid)','execute')
    and has_function_privilege('authenticated','public.list_leads_without_followup(public.lead_status,text,text,text,uuid)','execute'));
  perform pg_temp.chk('new helper functions are not executable by anon/authenticated',
    not has_function_privilege('anon','public.seed_lead_kinds(uuid)','execute') and not has_function_privilege('authenticated','public.seed_lead_kinds(uuid)','execute')
    and not has_function_privilege('anon','public.seed_lead_product_types(uuid)','execute') and not has_function_privilege('authenticated','public.seed_lead_product_types(uuid)','execute')
    and not has_function_privilege('anon','public.trg_seed_lead_lists()','execute') and not has_function_privilege('authenticated','public.trg_seed_lead_lists()','execute')
    and not has_function_privilege('anon','public._trg_lead_lists_sync()','execute') and not has_function_privilege('authenticated','public._trg_lead_lists_sync()','execute')
    and not has_function_privilege('anon','public._trg_lead_list_guard()','execute') and not has_function_privilege('authenticated','public._trg_lead_list_guard()','execute'));

  -- every lead created above has an open follow-up via the initial-followup trigger; filter by kind key as sales_admin
  perform pg_temp.as_user(v_sales);
  select count(*) into n from list_followups('all', null, null, 'warranty');
  perform pg_temp.chk('list_followups p_kind=warranty returns the custom-kind lead', n=1, n::text);
  select count(*) into n from list_followups('all', null, null, 'amc');
  perform pg_temp.chk('list_followups p_kind=amc returns the system-kind lead', n=1, n::text);
  select count(*) into n from list_followups('all', null, null, null);
  perform pg_temp.chk('list_followups unfiltered returns all org follow-ups', n >= 4, n::text);
  select kind into k from list_followups('all', null, null, 'warranty') limit 1;
  perform pg_temp.chk('returned kind column is the key text', k='warranty', coalesce(k,'null'));
  begin perform * from list_leads_without_followup(null, null, 'warranty'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('list_leads_without_followup accepts a text kind', b);
  perform pg_temp.as_pg();

  -- backfill left real leads' updated_at alone (only when the runner captured pre_fp) ---------------------
  if to_regclass('pg_temp.pre_fp') is not null then
    perform pg_temp.chk('backfill did not touch updated_at of existing leads', not exists (select 1 from pg_temp.pre_fp p join leads l on l.id=p.id where l.updated_at is distinct from p.updated_at));
    perform pg_temp.chk('every pre-existing lead with an enum kind got kind_key', not exists (select 1 from leads l join pg_temp.pre_fp p on p.id=l.id where l.kind is not null and l.kind_key is distinct from l.kind::text));
    perform pg_temp.chk('every pre-existing lead with a product_category got product_type_key', not exists (select 1 from leads l join pg_temp.pre_fp p on p.id=l.id where l.product_category is not null and l.product_type_key is distinct from l.product_category::text));
  end if;

  -- cleanup of a throwaway org: blocked normally, allowed with the explicit cleanup setting ------------------
  delete from leads where org_id in (v_org, v_org2);
  begin delete from lead_kinds where org_id=v_org2; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('system rows still protected without the cleanup setting', b=false);
  perform set_config('app.lead_lists_cleanup', 'on', true);
  delete from lead_kinds where org_id=v_org2;
  delete from lead_product_types where org_id=v_org2;
  perform pg_temp.chk('cleanup setting lets a throwaway org lists be removed', not exists (select 1 from lead_kinds where org_id=v_org2) and not exists (select 1 from lead_product_types where org_id=v_org2));
  perform set_config('app.lead_lists_cleanup', 'off', true);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
