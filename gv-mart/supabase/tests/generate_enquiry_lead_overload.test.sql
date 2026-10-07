-- After 20261010140000_drop_generate_enquiry_lead_6arg.sql: only the 7-argument form exists, and a
-- 6-argument call (named, typed, or untyped literals) resolves to it and works. Rolled back (ends in RAISE).
do $t$
declare
  res text := ''; v_org uuid; v_tp uuid := gen_random_uuid(); v_tid uuid; v_id uuid; n int; v_real int;
begin
  select count(*) into v_real from leads;
  select count(*) into n from pg_proc where proname='generate_enquiry_lead' and pronamespace='public'::regnamespace;
  res := res || E'\n' || case when n=1 then 'ok   exactly one generate_enquiry_lead overload exists' else 'FAIL overloads='||n end;
  select pronargs into n from pg_proc where proname='generate_enquiry_lead' and pronamespace='public'::regnamespace;
  res := res || E'\n' || case when n=7 then 'ok   it is the 7-argument form (p_visit_id defaulted)' else 'FAIL pronargs='||n end;

  insert into organizations(name) values ('__TEST_overload_org') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict do nothing;
  insert into auth.users(id,email) values (v_tp,'__test_'||v_tp||'@example.invalid');
  insert into profiles(id,org_id,full_name,role) values (v_tp,v_org,'__TEST_tech','technician');
  insert into technicians(org_id,profile_id) values (v_org,v_tp) returning id into v_tid;
  perform set_config('request.jwt.claims', json_build_object('sub',v_tp,'role','authenticated')::text, true);
  execute 'set local role authenticated';

  begin v_id := generate_enquiry_lead(v_org, null::uuid, '__TEST_a'::text, '9810000001'::text, 'price'::enquiry_type, 'note'::text);
        res := res || E'\n' || case when v_id is not null then 'ok   6 typed args resolve to the 7-arg form and work' else 'FAIL typed' end;
  exception when others then res := res || E'\n' || 'FAIL typed: '||sqlerrm; end;
  begin v_id := generate_enquiry_lead(p_org_id => v_org, p_customer_id => null, p_name => '__TEST_b', p_mobile => '9810000002', p_enquiry_type => 'price', p_note => 'n');
        res := res || E'\n' || case when v_id is not null then 'ok   6 NAMED args (the PostgREST call shape without p_visit_id) work' else 'FAIL named' end;
  exception when others then res := res || E'\n' || 'FAIL named: '||sqlerrm; end;
  begin v_id := generate_enquiry_lead(v_org, null, '__TEST_c', '9810000003', 'price', 'n', null);
        res := res || E'\n' || case when v_id is not null then 'ok   7 args (what sync.ts sends) work' else 'FAIL 7' end;
  exception when others then res := res || E'\n' || 'FAIL 7: '||sqlerrm; end;
  execute 'reset role';
  select count(*) into n from leads where org_id=v_org and source='field' and owner_id=v_tid and visit_id is null;
  res := res || E'\n' || case when n=3 then 'ok   3 field leads created, owner = the technician, visit null' else 'FAIL leads='||n end;
  select count(*) into n from leads where org_id <> v_org;
  res := res || E'\n' || case when n=v_real then 'ok   real leads untouched ('||n||')' else 'FAIL real leads changed' end;
  raise exception E'RESULTS:%', res;
end
$t$;
