-- Caller-by-caller proof for supabase/held/20261010130000_revoke_anon_lead_helpers.sql.
-- The runner concatenates the migration in front of this block in ONE transaction; the block ends in RAISE,
-- so the revokes are never committed. Throwaway __TEST_ organisation, users, customer, slot.
do $t$
declare
  res text := ''; v_org uuid; v_m uuid := gen_random_uuid(); v_ops uuid := gen_random_uuid(); v_tech uuid := gen_random_uuid();
  v_cu uuid := gen_random_uuid(); v_custid uuid; v_tid uuid; v_slot uuid; v_r uuid; n int; j jsonb;
begin
  insert into organizations(name) values ('__TEST_revoke_org') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict do nothing;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m,v_ops,v_tech,v_cu]) x;
  insert into profiles(id,org_id,full_name,role) values
    (v_m,v_org,'__TEST_m','master'),(v_ops,v_org,'__TEST_ops','operation_admin'),(v_tech,v_org,'__TEST_t','technician'),(v_cu,v_org,'__TEST_c','customer');
  insert into technicians(org_id,profile_id) values (v_org,v_tech) returning id into v_tid;
  insert into customers(org_id,name,mobile,primary_profile_id) values (v_org,'__TEST_cust','9600000001',v_cu) returning id into v_custid;
  insert into appointment_slots(org_id,name,start_time,end_time) values (v_org,'__TEST_slot','09:00','12:00') returning id into v_slot;

  -- 1 webhooks: wa_create_lead as service_role (what wasi-webhook / whatsapp-webhook use)
  execute 'set local role service_role';
  begin v_r := wa_create_lead(v_org,'919600000002',null,'__TEST_hello');
        res := res || E'\n' || case when v_r is not null then 'ok   1 service_role wa_create_lead (wasi-webhook/whatsapp-webhook path) creates a lead' else 'FAIL 1' end;
  exception when others then res := res || E'\n' || 'FAIL 1 '||sqlerrm; end;
  execute 'reset role';

  -- 2 simulate_inbound_whatsapp (staff test panel)
  foreach j in array array[jsonb_build_object('who',v_m,'name','master'),jsonb_build_object('who',v_ops,'name','operation_admin')] loop
    perform set_config('request.jwt.claims', json_build_object('sub',j->>'who','role','authenticated')::text, true);
    execute 'set local role authenticated';
    begin v_r := simulate_inbound_whatsapp(v_org,'919600000003','__TEST_ price please');
          select count(*) into n from leads where org_id=v_org and mobile='919600000003';
          res := res || E'\n' || case when v_r is not null and n=1 then 'ok   2 simulate_inbound_whatsapp as '||(j->>'name')||' works, lead created' else 'FAIL 2 '||(j->>'name') end;
    exception when others then res := res || E'\n' || 'FAIL 2 '||(j->>'name')||': '||sqlerrm; end;
    execute 'reset role';
  end loop;
  foreach j in array array[jsonb_build_object('who',v_tech,'name','technician'),jsonb_build_object('who',v_cu,'name','customer')] loop
    perform set_config('request.jwt.claims', json_build_object('sub',j->>'who','role','authenticated')::text, true);
    execute 'set local role authenticated';
    begin perform simulate_inbound_whatsapp(v_org,'919600000004','x'); res := res || E'\n' || 'FAIL 2b '||(j->>'name')||' could simulate';
    exception when others then res := res || E'\n' || 'ok   2b simulate_inbound_whatsapp as '||(j->>'name')||' rejected: '||sqlerrm; end;
    execute 'reset role';
  end loop;
  perform set_config('request.jwt.claims','',true);
  execute 'set local role anon';
  begin perform simulate_inbound_whatsapp(v_org,'919600000005','x'); res := res || E'\n' || 'FAIL 2c anon simulate';
  exception when others then res := res || E'\n' || 'ok   2c simulate_inbound_whatsapp as anon rejected: '||sqlerrm; end;
  execute 'reset role';

  -- 3 generate_enquiry_lead (technician offline sync)
  perform set_config('request.jwt.claims', json_build_object('sub',v_tech,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin v_r := generate_enquiry_lead(v_org, null::uuid, '__TEST_field'::text, '9600000006'::text, 'price'::enquiry_type, 'note'::text, null::uuid);
        res := res || E'\n' || case when v_r is not null then 'ok   3 generate_enquiry_lead as technician works (7-arg)' else 'FAIL 3' end;
  exception when others then res := res || E'\n' || 'FAIL 3 '||sqlerrm; end;
  begin v_r := generate_enquiry_lead(v_org, null::uuid, '__TEST_field6'::text, '9600000016'::text, 'price'::enquiry_type, 'note'::text);
        res := res || E'\n' || case when v_r is not null then 'ok   3b generate_enquiry_lead as technician works (6-arg)' else 'INFO 3b' end;
  exception when others then res := res || E'\n' || 'INFO 3b (pre-existing: 6-arg call is ambiguous with the 7-arg default overload) '||sqlerrm; end;
  execute 'reset role';
  execute 'set local role anon';
  begin perform generate_enquiry_lead(v_org, null::uuid, 'x'::text, '1'::text, 'price'::enquiry_type, 'n'::text, null::uuid); res := res || E'\n' || 'FAIL 3c anon';
  exception when others then res := res || E'\n' || 'ok   3c generate_enquiry_lead as anon rejected: '||sqlerrm; end;
  execute 'reset role';

  -- 4 customer app: request_callback and submit_customer_enquiry (definer callers of _find_recent_open_lead)
  perform set_config('request.jwt.claims', json_build_object('sub',v_cu,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin j := request_callback(v_org, (now() at time zone 'Asia/Kolkata')::date + 1, v_slot, null, 'cb');
        res := res || E'\n' || case when j ? 'lead_id' then 'ok   4a request_callback as customer works (calls _find_recent_open_lead)' else 'FAIL 4a' end;
  exception when others then res := res || E'\n' || 'FAIL 4a '||sqlerrm; end;
  begin v_r := submit_customer_enquiry(v_org,'product','price'::enquiry_type,'__TEST_enq','',null,'[]'::jsonb);
        res := res || E'\n' || case when v_r is not null then 'ok   4b submit_customer_enquiry as customer works' else 'FAIL 4b' end;
  exception when others then res := res || E'\n' || 'INFO 4b submit_customer_enquiry: '||sqlerrm; end;
  -- direct calls by a logged-in customer to the helpers must now fail
  begin perform _whatsapp_lead_upsert(v_org,'9600000009','price'::enquiry_type,'x'); res := res || E'\n' || 'FAIL 5a customer can call _whatsapp_lead_upsert';
  exception when others then res := res || E'\n' || 'ok   5a authenticated customer cannot call _whatsapp_lead_upsert: '||sqlerrm; end;
  begin perform _find_recent_open_lead(v_org,null,'9600000009'); res := res || E'\n' || 'FAIL 5b customer can call _find_recent_open_lead';
  exception when others then res := res || E'\n' || 'ok   5b authenticated customer cannot call _find_recent_open_lead: '||sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims','',true);
  execute 'set local role anon';
  begin perform _whatsapp_lead_upsert(v_org,'9600000009','price'::enquiry_type,'x'); res := res || E'\n' || 'FAIL 5c anon can call _whatsapp_lead_upsert';
  exception when others then res := res || E'\n' || 'ok   5c anon cannot call _whatsapp_lead_upsert: '||sqlerrm; end;
  begin perform _find_recent_open_lead(v_org,null,'9600000009'); res := res || E'\n' || 'FAIL 5d anon can call _find_recent_open_lead';
  exception when others then res := res || E'\n' || 'ok   5d anon cannot call _find_recent_open_lead: '||sqlerrm; end;
  execute 'reset role';

  select count(*) into n from leads where org_id not in (v_org);
  res := res || E'\n' || 'info real leads untouched, total outside test org = '||n;
  raise exception E'RESULTS:%', res;
end
$t$;
