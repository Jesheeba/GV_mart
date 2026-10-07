-- Rolled-back smoke test of the main screens' data access per persona (throwaway __TEST_ org).
-- Run BEFORE and AFTER applying 20261010110000_staff_helpers_require_active.sql and diff the matrices:
-- only the "sales_admin inactive" rows may change. Always ends in RAISE (nothing persists).
do $t$
declare
  res text := ''; v_org uuid; v_cust uuid; v_tk uuid; v_tech_id uuid; v_inv uuid;
  ids jsonb := '{}'; v_id uuid; k text; n_l int; n_c int; n_i int; n_q int; n_t int; n_a int; n_f int; n_fc int;
  ins_l int; ins_c int; ins_q int; ins_i int; ins_t int; personas text[] := array['master','operation_admin','technician','sales_admin_active','sales_admin_inactive'];
  v_role text; v_act boolean;
begin
  insert into organizations(name) values ('__TEST_smoke_org') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict do nothing;
  foreach k in array personas loop
    v_id := gen_random_uuid();
    v_role := case when k like 'sales_admin%' then 'sales_admin' else k end;
    v_act := k <> 'sales_admin_inactive';
    insert into auth.users(id,email) values (v_id,'__test_'||v_id||'@example.invalid');
    insert into profiles(id,org_id,full_name,role,is_active) values (v_id,v_org,'__TEST_'||k,v_role::user_role,v_act);
    ids := ids || jsonb_build_object(k, v_id);
  end loop;
  insert into technicians(org_id,profile_id) values (v_org,(ids->>'technician')::uuid) returning id into v_tech_id;
  -- seed (as postgres)
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_cust','9300000001') returning id into v_cust;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_lead','9300000002');
  insert into quotations(org_id,customer_id) values (v_org,v_cust);
  insert into invoices(org_id,customer_id,type) values (v_org,v_cust,'product');
  insert into service_tickets(org_id,customer_id) values (v_org,v_cust) returning id into v_tk;
  insert into appointments(org_id,ticket_id) values (v_org,v_tk);

  foreach k in array personas loop
    perform set_config('request.jwt.claims', json_build_object('sub',ids->>k,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n_l from leads where org_id=v_org;
    select count(*) into n_c from customers where org_id=v_org;
    select count(*) into n_i from invoices where org_id=v_org;
    select count(*) into n_q from quotations where org_id=v_org;
    select count(*) into n_t from service_tickets where org_id=v_org;
    select count(*) into n_a from appointments where org_id=v_org;
    select count(*) into n_f from lead_followups where org_id=v_org;
    begin select count(*) into n_fc from list_followups('today',null,null,null,false,'mine',null); exception when others then n_fc := -1; end;
    begin insert into leads(org_id,name,mobile) values (v_org,'__TEST_i_'||k,'9300000010'); ins_l:=1; exception when others then ins_l:=0; end;
    begin insert into customers(org_id,name,mobile) values (v_org,'__TEST_ci_'||k,'93000000'||(10+array_position(personas,k))); ins_c:=1; exception when others then ins_c:=0; end;
    begin insert into quotations(org_id,customer_id) values (v_org,v_cust); ins_q:=1; exception when others then ins_q:=0; end;
    begin insert into invoices(org_id,customer_id,type) values (v_org,v_cust,'product'); ins_i:=1; exception when others then ins_i:=0; end;
    begin insert into service_tickets(org_id,customer_id) values (v_org,v_cust); ins_t:=1; exception when others then ins_t:=0; end;
    execute 'reset role';
    res := res || E'\n' || format('%-22s see[leads=%s cust=%s inv=%s quo=%s tickets=%s appts=%s followups=%s myday_rpc=%s] insert[lead=%s cust=%s quo=%s inv=%s ticket=%s]',
      k,n_l,n_c,n_i,n_q,n_t,n_a,n_f,n_fc,ins_l,ins_c,ins_q,ins_i,ins_t);
    -- undo this persona's inserts so each persona sees the same seeded data
    delete from leads where org_id=v_org and name like '__TEST_i\_%';
    delete from customers where org_id=v_org and name like '__TEST_ci\_%';
    delete from quotations where org_id=v_org and id not in (select min(id::text)::uuid from quotations where org_id=v_org);
    delete from invoices where org_id=v_org and id not in (select min(id::text)::uuid from invoices where org_id=v_org);
    delete from service_tickets where org_id=v_org and id <> v_tk;
  end loop;
  raise exception E'MATRIX:%', res;
end
$t$;
