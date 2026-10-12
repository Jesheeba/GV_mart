-- Rolled-back test for held/20261015140000_anon_hygiene_and_stale_booking_guard.sql (runner: migration, then this block).
-- Throwaway __TEST_ organisations only. resolve_stale_bookings is exercised with a real stale booking so the sweep is proven to still work.
do $t$
declare
  res text := ''; v_org uuid; v_org2 uuid; v_ids jsonb := '{}'::jsonb; r record; v_u uuid; n int; v_cust uuid; v_tk uuid; v_ap uuid;
  v_inv uuid;
begin
  insert into organizations(name) values ('__TEST_stale_guard') returning id into v_org;
  insert into organizations(name) values ('__TEST_stale_guard_other') returning id into v_org2;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  for r in select * from (values
      ('customer','customer',true,false),('technician','technician',true,true),('technician_inactive','technician',true,false),
      ('master','master',true,false),('ops','operation_admin',true,false),('sales','sales_admin',true,false),
      ('ops_inactive','operation_admin',false,false),('noprofile',null,true,false),('othercustomer','customer',true,false)) t(n,ro,ac,tech)
  loop
    v_u := gen_random_uuid(); v_ids := v_ids || jsonb_build_object(r.n, v_u);
    insert into auth.users(id,email) values (v_u,'__test_'||v_u||'@example.invalid');
    if r.ro is not null then
      insert into profiles(id,org_id,full_name,role,is_active) values (v_u, case when r.n='othercustomer' then v_org2 else v_org end,'__TEST_'||r.n,r.ro::user_role,r.ac);
      if r.ro = 'technician' then insert into technicians(org_id,profile_id,is_active) values (v_org, v_u, r.tech); end if;
      if r.ro = 'customer' and r.n = 'customer' then
        insert into customers(org_id,name,mobile,primary_profile_id) values (v_org,'__TEST_c','9000000001',v_u);
      end if;
    end if;
  end loop;
  select id into v_cust from customers where org_id=v_org limit 1;

  -- allowed personas (each on a fresh stale appointment, so the sweep has something to do)
  for r in select * from (values ('customer'),('technician'),('master'),('ops'),('sales')) t(n) loop
    insert into service_tickets(org_id,customer_id,name_of_complaint,status) values (v_org,v_cust,'__TEST_stale','open') returning id into v_tk;
    insert into appointments(org_id,ticket_id,scheduled_at,status) values (v_org,v_tk,now() - interval '3 days','scheduled') returning id into v_ap;
    perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>r.n)::uuid,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    begin n := resolve_stale_bookings(v_org);
      execute 'reset role';
      res := res || E'\n' || case when n >= 1 and (select follow_up_flagged_at from appointments where id=v_ap) is not null
                             then 'ok   '||rpad(r.n,20)||' allowed, swept '||n else 'FAIL '||r.n||' swept '||n end;
    exception when others then execute 'reset role'; res := res || E'\nFAIL '||r.n||' '||sqlerrm; end;
  end loop;

  -- refused personas
  for r in select * from (values ('technician_inactive'),('ops_inactive'),('noprofile'),('othercustomer')) t(n) loop
    perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>r.n)::uuid,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    begin n := resolve_stale_bookings(v_org); execute 'reset role'; res := res || E'\nFAIL '||r.n||' was allowed';
    exception when others then execute 'reset role'; res := res || E'\nok   '||rpad(r.n,20)||' refused: '||left(sqlerrm,60); end;
  end loop;

  -- anon: privilege (EXECUTE for anon is still granted by default; the identity check refuses)
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin n := resolve_stale_bookings(v_org); execute 'reset role'; res := res || E'\nFAIL anon allowed';
  exception when others then execute 'reset role'; res := res || E'\nok   anon                 refused: '||left(sqlerrm,60); end;

  -- service role (Edge Function / job)
  perform set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  execute 'set local role service_role';
  begin n := resolve_stale_bookings(v_org); execute 'reset role'; res := res || E'\nok   service_role         allowed, swept '||n;
  exception when others then execute 'reset role'; res := res || E'\nFAIL service_role '||sqlerrm; end;

  -- ===== the nine revoked functions =====
  for r in select p.oid::regprocedure sig, p.proname from pg_proc p where p.pronamespace='public'::regnamespace
            and p.proname in ('wa_get_business_info','wa_get_emi_info','wa_get_products_by_category','wa_supplier_latest_sent_po',
              'technician_installation_count','_next_ticket_available_for_technician','_customer_exemption_blocks',
              '_derive_payment_status','_largest_free_window')
  loop
    res := res || E'\n' || case when not has_function_privilege('anon', r.sig, 'execute') and not has_function_privilege('authenticated', r.sig, 'execute')
                                  and has_function_privilege('service_role', r.sig, 'execute')
                           then 'ok   ACL '||r.proname else 'FAIL ACL '||r.proname end;
  end loop;

  -- ===== definer callers of the helpers still work =====
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_c2','9000000002') returning id into v_cust;
  insert into invoices(org_id,customer_id,type,subtotal,discount,gst,total,payment_status,amount_paid)
    values (v_org,v_cust,'product',100,0,18,118,'due',0) returning id into v_inv;
  perform set_config('request.jwt.claims', json_build_object('sub',(v_ids->>'master')::uuid,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform record_additional_payment(v_org, v_inv, 118, 'cash');
    execute 'reset role';
    res := res || E'\n' || case when (select payment_status::text from invoices where id=v_inv) = 'paid'
                           then 'ok   record_additional_payment (calls revoked _derive_payment_status) still marks the invoice paid' else 'FAIL record_additional_payment status' end;
  exception when others then execute 'reset role'; res := res || E'\nFAIL record_additional_payment '||sqlerrm; end;
  begin perform compute_incentives(v_org, date_trunc('month', current_date)::date);
    execute 'reset role';
    res := res || E'\nok   compute_incentives (calls revoked technician_installation_count) still runs';
  exception when others then execute 'reset role'; res := res || E'\nFAIL compute_incentives '||sqlerrm; end;

  raise exception E'RESULTS:%', res;
end
$t$;
