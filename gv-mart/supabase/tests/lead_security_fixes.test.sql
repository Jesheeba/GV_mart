-- Rolled-back RLS check for 20261006171000_lead_security_fixes.sql. Run through the Management API
-- (database/query); it always ends in a RAISE so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_sales uuid; v_tech uuid; v_cust uuid; v_techid uuid; v_custid uuid;
  v_lead uuid; v_act uuid; v_item uuid; n int; v_lead2 uuid;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select id into v_sales from profiles where role='sales_admin' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select c.primary_profile_id, c.id into v_cust, v_custid from customers c where primary_profile_id is not null limit 1;
  insert into leads(org_id,name,mobile) values (v_org,'__T1_victim','9000000001') returning id into v_lead;
  insert into lead_activities(org_id,lead_id,type,note) values (v_org,v_lead,'note','x') returning id into v_act;
  insert into lead_items(org_id,lead_id,qty) values (v_org,v_lead,1) returning id into v_item;

  -- sales_admin direct deletes
  perform set_config('request.jwt.claims', json_build_object('sub',v_sales,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  delete from leads where id=v_lead; get diagnostics n = row_count; res := res || E'
' || format('sales_admin direct DELETE leads: %s row(s)', n);
  delete from lead_activities where id=v_act; get diagnostics n = row_count; res := res || E'
' || format('sales_admin direct DELETE lead_activities: %s row(s)', n);
  delete from lead_items where id=v_item; get diagnostics n = row_count; res := res || E'
' || format('sales_admin direct DELETE lead_items: %s row(s)', n);
  begin update lead_activities set note='tampered' where id=v_act; get diagnostics n = row_count; res := res || E'
' || format('sales_admin UPDATE lead_activities: %s row(s)', n); exception when others then res := res || E'
' || 'sales_admin UPDATE lead_activities error: '||sqlerrm; end;
  -- sales_admin still can insert/update leads
  begin insert into leads(org_id,name,status) values (v_org,'__T1_sales_new','new') returning id into v_lead2; res := res || E'
' || 'sales_admin INSERT lead: ok'; exception when others then res := res || E'
' || 'sales_admin INSERT lead ERR: '||sqlerrm; end;
  begin update leads set status='contacted' where id=v_lead2; get diagnostics n = row_count; res := res || E'
' || format('sales_admin UPDATE lead: %s row(s)', n); exception when others then res := res || E'
' || 'sales_admin UPDATE lead ERR: '||sqlerrm; end;
  begin perform delete_lead(v_lead2); res := res || E'
' || 'sales_admin delete_lead: SUCCEEDED (bad)'; exception when others then res := res || E'
' || 'sales_admin delete_lead: rejected ('||sqlerrm||')'; end;
  execute 'reset role';

  -- customer inserts
  perform set_config('request.jwt.claims', json_build_object('sub',v_cust,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into leads(org_id,customer_id,name,status) values (v_org,v_custid,'__T1_cust_won','won'); res := res || E'
' || 'customer INSERT status=won: SUCCEEDED (bad)'; exception when others then res := res || E'
' || 'customer INSERT status=won: rejected'; end;
  begin insert into leads(org_id,customer_id,name,status) values (v_org,v_custid,'__T1_cust_new','new'); res := res || E'
' || 'customer INSERT status=new: ok'; exception when others then res := res || E'
' || 'customer INSERT status=new ERR: '||sqlerrm; end;
  execute 'reset role';

  -- technician inserts
  perform set_config('request.jwt.claims', json_build_object('sub',v_tech,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into leads(org_id,name,status,owner_id) values (v_org,'__T1_tech_won','won',v_techid); res := res || E'
' || 'technician INSERT status=won: SUCCEEDED (bad)'; exception when others then res := res || E'
' || 'technician INSERT status=won: rejected'; end;
  begin insert into leads(org_id,name,status,owner_id) values (v_org,'__T1_tech_new','new',v_techid); res := res || E'
' || 'technician INSERT status=new: ok'; exception when others then res := res || E'
' || 'technician INSERT status=new ERR: '||sqlerrm; end;
  execute 'reset role';

  -- master delete via RPC
  perform set_config('request.jwt.claims', json_build_object('sub',v_master,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform delete_lead(v_lead); res := res || E'
' || 'master delete_lead: ok'; exception when others then res := res || E'
' || 'master delete_lead ERR: '||sqlerrm; end;
  execute 'reset role';
  select count(*) into n from leads where id=v_lead; res := res || E'
' || format('victim lead rows left after master delete_lead: %s', n);
  raise exception E'RESULTS%', res;
end $t$;
