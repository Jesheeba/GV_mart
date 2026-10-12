-- Rolled-back test for held/20261015100000_whatsapp_outbound_gate.sql (F-08).
-- The runner puts the migration in front of this block in ONE transaction and the block ends in RAISE, so nothing is
-- committed and nothing is ever dispatched (these rows are never read by the Edge Functions inside the rolled-back txn).
-- Throwaway __TEST_ organisation, users and numbers only.
do $t$
declare
  res text := ''; v_org uuid; v_m uuid := gen_random_uuid(); v_s uuid := gen_random_uuid(); v_c uuid := gen_random_uuid();
  v_cust uuid; v_cust2 uuid; v_tk uuid; v_inv uuid; v_sup uuid; v_po uuid; v_id uuid; n int; v_org2 uuid; v_tk2 uuid; v_cust3 uuid;
begin
  insert into organizations(name) values ('__TEST_wa_gate') returning id into v_org;
  insert into organizations(name) values ('__TEST_wa_gate_other') returning id into v_org2;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_s,v_c]) x;
  insert into profiles(id,org_id,full_name,role) values (v_m,v_org,'__TEST_master','master'),(v_s,v_org,'__TEST_sales','sales_admin'),(v_c,v_org,'__TEST_cust','customer');
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_cust1','9000000001') returning id into v_cust;
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_cust2','9000000002') returning id into v_cust2;
  insert into customer_members(org_id,customer_id,name,mobile) values (v_org,v_cust,'__TEST_member','9000000011');
  insert into customers(org_id,name,mobile) values (v_org2,'__TEST_other_org_cust','9000000003') returning id into v_cust3;
  insert into service_tickets(org_id,customer_id,name_of_complaint) values (v_org,v_cust,'__TEST_t') returning id into v_tk;
  insert into service_tickets(org_id,customer_id,name_of_complaint) values (v_org2,v_cust3,'__TEST_t_other') returning id into v_tk2;
  insert into suppliers(org_id,name,whatsapp) values (v_org,'__TEST_sup','9000000099') returning id into v_sup;
  insert into purchase_orders(org_id,supplier_id,status,total) values (v_org,v_sup,'draft',0) returning id into v_po;

  -- ===== structure =====
  res := res || E'\n' || case when not exists (select 1 from pg_policies where tablename='whatsapp_outbox' and cmd='INSERT')
                         then 'ok   G1 no INSERT policy on whatsapp_outbox' else 'FAIL G1 an INSERT policy remains' end;
  res := res || E'\n' || case when not has_table_privilege('authenticated','public.whatsapp_outbox','INSERT')
                              and not has_table_privilege('anon','public.whatsapp_outbox','INSERT')
                              and has_table_privilege('authenticated','public.whatsapp_outbox','SELECT')
                         then 'ok   G2 authenticated/anon cannot INSERT, authenticated can still SELECT' else 'FAIL G2' end;
  res := res || E'\n' || case when not has_function_privilege('authenticated','public.send_whatsapp_stub(uuid,text,uuid,text,text,jsonb,text,uuid)','execute')
                              and not has_function_privilege('anon','public.send_whatsapp_stub(uuid,text,uuid,text,text,jsonb,text,uuid)','execute')
                         then 'ok   G3 send_whatsapp_stub not executable by authenticated/anon' else 'FAIL G3' end;
  res := res || E'\n' || case when has_function_privilege('authenticated','public.send_staff_whatsapp(uuid,text,uuid,text,text,jsonb,text,uuid)','execute')
                              and not has_function_privilege('anon','public.send_staff_whatsapp(uuid,text,uuid,text,text,jsonb,text,uuid)','execute')
                         then 'ok   G4 send_staff_whatsapp: authenticated yes, anon no' else 'FAIL G4' end;

  -- ===== as the sales_admin =====
  perform set_config('request.jwt.claims', json_build_object('sub',v_s,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into whatsapp_outbox(org_id,direction,to_mobile,template,payload,ref_type,ref_id,status)
        values (v_org,'outbound','9111111111','x','{"body":"hi"}','service_ticket',v_tk,'sent');
        res := res || E'\nFAIL D1 staff direct INSERT succeeded';
  exception when others then res := res || E'\nok   D1 staff direct INSERT refused'; end;
  begin perform send_whatsapp_stub(v_org,'9111111111',null,'m','t','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL D2 staff called the stub';
  exception when others then res := res || E'\nok   D2 staff cannot call send_whatsapp_stub'; end;

  -- valid: the ticket's customer, and one of that customer's members
  begin v_id := send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{"body":"hi"}'::jsonb,'service_ticket',v_tk);
        res := res || E'\n' || case when v_id is not null then 'ok   V1 customer number on own ticket accepted' else 'FAIL V1 returned null' end;
  exception when others then res := res || E'\nFAIL V1 '||sqlerrm; end;
  begin v_id := send_staff_whatsapp(v_org,'+91 90000 00011',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\n' || case when v_id is not null then 'ok   V2 member number (formatted +91) accepted' else 'FAIL V2' end;
  exception when others then res := res || E'\nFAIL V2 '||sqlerrm; end;
  begin v_id := send_staff_whatsapp(v_org,'9000000099',null,'po','po.sent','{}'::jsonb,'purchase_order',v_po);
        res := res || E'\n' || case when v_id is not null then 'ok   V3 supplier number on own PO accepted' else 'FAIL V3' end;
  exception when others then res := res || E'\nFAIL V3 '||sqlerrm; end;

  -- refused
  begin perform send_staff_whatsapp(v_org,'9111111111',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL R1 arbitrary number accepted';
  exception when others then res := res || E'\nok   R1 number not on the record refused: '||sqlerrm; end;
  begin perform send_staff_whatsapp(v_org,'9000000002',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL R2 another customer''s number accepted';
  exception when others then res := res || E'\nok   R2 a different customer''s number refused'; end;
  begin perform send_staff_whatsapp(v_org,'9000000003',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk2);
        res := res || E'\nFAIL R3 ticket of another organisation accepted';
  exception when others then res := res || E'\nok   R3 record of another organisation refused'; end;
  begin perform send_staff_whatsapp(v_org2,'9000000003',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk2);
        res := res || E'\nFAIL R4 p_org_id of another organisation accepted';
  exception when others then res := res || E'\nok   R4 organisation mismatch refused'; end;
  begin perform send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'service_ticket',gen_random_uuid());
        res := res || E'\nFAIL R5 nonexistent record accepted';
  exception when others then res := res || E'\nok   R5 nonexistent record refused'; end;
  begin perform send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'whatsapp_outbox',v_tk);
        res := res || E'\nFAIL R6 unsupported ref_type accepted';
  exception when others then res := res || E'\nok   R6 unsupported ref_type refused'; end;
  begin perform send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'service_ticket',null);
        res := res || E'\nFAIL R7 null ref accepted';
  exception when others then res := res || E'\nok   R7 missing ref refused'; end;
  begin perform send_staff_whatsapp(v_org,'9000000001',v_cust2,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL R8 mismatched customer id accepted';
  exception when others then res := res || E'\nok   R8 customer id that does not match the record refused'; end;
  execute 'reset role';

  -- customer / anon cannot use it
  perform set_config('request.jwt.claims', json_build_object('sub',v_c,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL R9 customer sent a staff message';
  exception when others then res := res || E'\nok   R9 customer refused'; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin perform send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\nFAIL R10 anon sent';
  exception when others then res := res || E'\nok   R10 anon refused'; end;
  execute 'reset role';

  -- sender logged
  select count(*) into n from whatsapp_outbox where org_id=v_org and sent_by=v_s;
  res := res || E'\n' || case when n=3 then 'ok   L1 sent_by recorded on the 3 accepted rows' else 'FAIL L1 rows='||n end;
  select count(*) into n from audit_log where org_id=v_org and action='WA_STAFF_SEND' and actor_id=v_s and after ? 'to_last4' and not (after::text like '%9000000001%');
  res := res || E'\n' || case when n=3 then 'ok   L2 audit rows written, only the last 4 digits kept' else 'FAIL L2 audit rows='||n end;

  -- ===== test mode =====
  perform set_config('request.jwt.claims', json_build_object('sub',v_s,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update settings set wa_test_mode_enabled = true where org_id=v_org; get diagnostics n = row_count;
        res := res || E'\n' || case when n=0 then 'ok   T1 sales_admin cannot change test mode (no row visible/updatable)' else 'FAIL T1 sales_admin changed test mode' end;
  exception when others then res := res || E'\nok   T1 sales_admin refused: '||sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = array['9000000001'] where org_id=v_org; get diagnostics n = row_count;
        res := res || E'\n' || case when n=1 then 'ok   T2 master can turn test mode on and set the list' else 'FAIL T2 rows='||n end;
  exception when others then res := res || E'\nFAIL T2 '||sqlerrm; end;
  begin update settings set wa_test_allowed_numbers = array['12345'] where org_id=v_org;
        res := res || E'\nFAIL T3 invalid number stored';
  exception when others then res := res || E'\nok   T3 non-10-digit list entry refused'; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',v_s,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin v_id := send_staff_whatsapp(v_org,'9000000011',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\n' || case when v_id is null then 'ok   T4 test mode ON: member number not on the list is blocked (null, no outbox row)' else 'FAIL T4 sent' end;
  exception when others then res := res || E'\nFAIL T4 '||sqlerrm; end;
  begin v_id := send_staff_whatsapp(v_org,'9000000001',null,'ticket','tpl','{}'::jsonb,'service_ticket',v_tk);
        res := res || E'\n' || case when v_id is not null then 'ok   T5 test mode ON: listed number still goes through' else 'FAIL T5 blocked' end;
  exception when others then res := res || E'\nFAIL T5 '||sqlerrm; end;
  execute 'reset role';
  select count(*) into n from audit_log where org_id=v_org and action='WA_SEND_BLOCKED';
  res := res || E'\n' || case when n=1 then 'ok   T6 the blocked attempt is logged' else 'FAIL T6 blocked rows='||n end;
  update settings set wa_test_mode_enabled=false where org_id=v_org;
  res := res || E'\n' || case when (select wa_test_mode_enabled from settings where org_id=v_org) = false
                         then 'ok   T7 test mode can be switched back OFF' else 'FAIL T7' end;
  res := res || E'\n' || case when (select column_default from information_schema.columns
                                     where table_name='settings' and column_name='wa_test_mode_enabled') = 'false'
                         then 'ok   T8 test mode ships OFF (column default false)' else 'FAIL T8' end;

  -- ===== create_purchase_order still works end to end through the checked door =====
  insert into spares(org_id,name,price) values (v_org,'__TEST_spare',10) returning id into v_id;
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    v_po := create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_id,'qty',2,'price',10)));
    select count(*) into n from whatsapp_outbox where org_id=v_org and ref_type='purchase_order' and ref_id=v_po and sent_by=v_m;
    res := res || E'\n' || case when n=1 then 'ok   P1 create_purchase_order queued the supplier message through send_staff_whatsapp' else 'FAIL P1 rows='||n end;
  exception when others then res := res || E'\nFAIL P1 '||sqlerrm; end;
  execute 'reset role';
  update suppliers set whatsapp = null where id = v_sup;
  execute 'set local role authenticated';
  begin
    v_po := create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_id,'qty',1,'price',10)));
    res := res || E'\nok   P2 a supplier without a WhatsApp number does not break PO creation';
  exception when others then res := res || E'\nFAIL P2 '||sqlerrm; end;
  execute 'reset role';
  raise exception E'RESULTS:%', res;
end
$t$;
