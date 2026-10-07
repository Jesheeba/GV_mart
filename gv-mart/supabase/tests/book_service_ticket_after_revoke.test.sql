-- End-to-end proof that book_service_ticket still works, and still finds/creates the lead, after the held
-- 20261010130000_revoke_anon_lead_helpers.sql. The runner concatenates that migration in front of this block in ONE
-- transaction; the block ends in RAISE so nothing is committed. Throwaway __TEST_ organisation/customer/address/product.
do $t$
declare
  res text := ''; v_org uuid; v_cu uuid := gen_random_uuid(); v_cust uuid; v_addr uuid; v_brand uuid; v_model uuid; v_prod uuid;
  r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; n int; v_date date := (now() at time zone 'Asia/Kolkata')::date + 2;
  v_real int;
begin
  select count(*) into v_real from leads;
  insert into organizations(name) values ('__TEST_bst_org') returning id into v_org;
  insert into settings(org_id) select v_org where not exists (select 1 from settings where org_id=v_org);
  update settings set work_start='09:00', work_end='18:00' where org_id=v_org;
  insert into auth.users(id,email) values (v_cu,'__test_'||v_cu||'@example.invalid');
  insert into profiles(id,org_id,full_name,role) values (v_cu,v_org,'__TEST_cust','customer');
  insert into customers(org_id,name,mobile,primary_profile_id) values (v_org,'__TEST_customer','9700000001',v_cu) returning id into v_cust;
  insert into addresses(org_id,customer_id) values (v_org,v_cust) returning id into v_addr;
  insert into brands(org_id,name,category) values (v_org,'__TEST_brand','ro') returning id into v_brand;
  insert into models(org_id,brand_id,name) values (v_org,v_brand,'__TEST_model') returning id into v_model;
  insert into products(org_id,brand_id,model_id,name,category,price) values (v_org,v_brand,v_model,'__TEST_product','ro',1000) returning id into v_prod;

  perform set_config('request.jwt.claims', json_build_object('sub',v_cu,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  -- A: booking WITH a product: ticket + appointment created, no lead (the lead path is for no-product bookings)
  begin
    r1 := book_service_ticket(v_org, v_addr, v_prod, v_brand, v_model, '__TEST_issue A', 'n', 'normal', v_date, '[]'::jsonb, null);
    res := res || E'\n' || case when r1 ? 'ticket_id' and r1 ? 'appointment_id' and (r1->>'lead_id') is null then 'ok   A booking with product works: ticket+appointment, no lead (as designed)' else 'FAIL A '||r1::text end;
  exception when others then res := res || E'\n' || 'FAIL A '||sqlerrm; end;

  -- B: booking WITHOUT a product, no open lead yet: lead is CREATED through _find_recent_open_lead (now revoked from clients)
  begin
    r2 := book_service_ticket(v_org, v_addr, null, null, null, '__TEST_issue B', 'n', 'normal', v_date, '[]'::jsonb, null);
    select count(*) into n from leads where id=(r2->>'lead_id')::uuid and customer_id=v_cust and source='customer_app' and kind='service';
    res := res || E'\n' || case when n=1 then 'ok   B no-product booking created a lead after the revoke' else 'FAIL B '||r2::text end;
  exception when others then res := res || E'\n' || 'FAIL B '||sqlerrm; end;

  -- C: second booking, same customer/mobile: REUSES the open lead, adds an activity
  begin
    r3 := book_service_ticket(v_org, v_addr, null, null, null, '__TEST_issue C', 'n', 'normal', v_date, '[]'::jsonb, null);
    select count(*) into n from leads where org_id=v_org;
    res := res || E'\n' || case when (r3->>'lead_id') = (r2->>'lead_id') and n=1 then 'ok   C second booking reused the same open lead (leads in org: '||n||')' else 'FAIL C '||r3::text||' leads='||n end;
    execute 'reset role';  -- customers cannot read lead_activities; count as the table owner
    select count(*) into n from lead_activities where lead_id=(r2->>'lead_id')::uuid and type='service_enquiry';
    execute 'set local role authenticated';
    res := res || E'\n' || case when n=2 then 'ok   C2 both complaints logged as activities on that lead' else 'FAIL C2 n='||n end;
  exception when others then res := res || E'\n' || 'FAIL C '||sqlerrm; end;

  -- D: after the lead is closed, a new no-product booking creates a fresh lead
  execute 'reset role';
  update leads set status='lost' where id=(r2->>'lead_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub',v_cu,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    r4 := book_service_ticket(v_org, v_addr, null, null, null, '__TEST_issue D', 'n', 'normal', v_date, '[]'::jsonb, null);
    res := res || E'\n' || case when (r4->>'lead_id') is not null and (r4->>'lead_id') <> (r2->>'lead_id') then 'ok   D after the old lead closed, a new lead is created' else 'FAIL D '||r4::text end;
  exception when others then res := res || E'\n' || 'FAIL D '||sqlerrm; end;

  -- E: the helpers are really closed to this logged-in customer
  begin perform _find_recent_open_lead(v_org, v_cust, null); res := res || E'\n' || 'FAIL E helper callable';
  exception when others then res := res || E'\n' || 'ok   E customer still cannot call _find_recent_open_lead directly'; end;
  execute 'reset role';

  select count(*) into n from leads where org_id <> v_org;
  res := res || E'\n' || case when n=v_real then 'ok   real leads untouched ('||n||')' else 'FAIL real leads changed' end;
  raise exception E'RESULTS:%', res;
end
$t$;
