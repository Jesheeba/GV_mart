-- F-07 role x is_active matrix, PART 1 (before). Runner order, ONE transaction, ends in RAISE (nothing committed):
--   tests/current_role_active_gate_1_before.sql, held/20261015110000_current_role_active_gate.sql,
--   tests/current_role_active_gate_2_after.sql
-- Throwaway __TEST_ organisations and users only.

create temp table mx_persona(name text primary key, uid uuid not null, org uuid not null);
create temp table mx_ids(k text primary key, v uuid not null);
create temp table mx_out(phase text, persona text, k text, v text);

do $f$
declare
  v_org uuid; v_org2 uuid; r record; v_cust uuid; v_lead uuid; v_sup uuid; v_po uuid; v_tech uuid; v_prod uuid;
begin
  insert into organizations(name) values ('__TEST_f07_matrix') returning id into v_org;
  insert into organizations(name) values ('__TEST_f07_matrix_other') returning id into v_org2;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings(org_id) values (v_org2) on conflict (org_id) do nothing;

  -- personas: (name, role, is_active)
  for r in select * from (values
      ('master_active','master',true),('master_inactive','master',false),
      ('ops_active','operation_admin',true),('ops_inactive','operation_admin',false),
      ('sales_active','sales_admin',true),('sales_inactive','sales_admin',false),
      ('technician','technician',true),('customer','customer',true)) v(n,ro,ac)
  loop
    insert into mx_persona(name, uid, org) values (r.n, gen_random_uuid(), v_org);
    insert into auth.users(id,email) select uid,'__test_'||uid||'@example.invalid' from mx_persona where name=r.n;
    insert into profiles(id,org_id,full_name,role,is_active)
      select uid, v_org, '__TEST_'||r.n, r.ro::user_role, r.ac from mx_persona where name=r.n;
  end loop;
  -- signed in with NO profile
  insert into mx_persona(name, uid, org) values ('no_profile', gen_random_uuid(), v_org);
  insert into auth.users(id,email) select uid,'__test_'||uid||'@example.invalid' from mx_persona where name='no_profile';

  insert into customers(org_id,name,mobile) values (v_org,'__TEST_cust','9000000001') returning id into v_cust;
  perform set_config('app.lead_assign_ok', '1', true);   -- fixture only: leads are otherwise created unassigned
  insert into leads(org_id,name,mobile,source,status,assigned_to)
    values (v_org,'__TEST_lead','9000000002','walk_in','new',(select uid from mx_persona where name='sales_active')) returning id into v_lead;
  perform set_config('app.lead_assign_ok', '', true);
  insert into suppliers(org_id,name,whatsapp) values (v_org,'__TEST_sup','9000000099') returning id into v_sup;
  insert into purchase_orders(org_id,supplier_id,status,total) values (v_org,v_sup,'sent',10) returning id into v_po;
  insert into service_tickets(org_id,customer_id,name_of_complaint) values (v_org,v_cust,'__TEST_t');
  insert into invoices(org_id,customer_id,type,subtotal,discount,gst,total,payment_status,amount_paid)
    values (v_org,v_cust,'product',100,0,18,118,'due',0);
  insert into mx_ids values ('org',v_org),('cust',v_cust),('lead',v_lead),('po',v_po),('rnd',gen_random_uuid());
end
$f$;

-- the matrix: runs every persona through the helpers, a set of RLS-governed counts and a set of guarded RPCs
create or replace function pg_temp.mx_run(p_phase text) returns void language plpgsql as $m$
declare
  p record; v_org uuid := (select v from mx_ids where k='org'); v_cust uuid := (select v from mx_ids where k='cust');
  v_lead uuid := (select v from mx_ids where k='lead'); v_po uuid := (select v from mx_ids where k='po');
  v_rnd uuid := (select v from mx_ids where k='rnd');
  q record; v text; v_buf jsonb;
begin
  for p in select * from mx_persona order by name loop
    perform set_config('request.jwt.claims', json_build_object('sub',p.uid,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    v_buf := jsonb_build_object('current_role', coalesce(public.current_role()::text,'NULL'));
    -- helpers
    v_buf := v_buf || jsonb_build_object('is_master', coalesce(public.is_master()::text,'NULL'), 'is_ops_staff', coalesce(public.is_ops_staff()::text,'NULL'),
                                         'is_staff', coalesce(public.is_staff()::text,'NULL'), 'is_sales_staff', coalesce(public.is_sales_staff()::text,'NULL'));
    -- RLS-governed visible counts
    for q in select * from (values
        ('cnt_leads','select count(*) from public.leads'),
        ('cnt_customers','select count(*) from public.customers'),
        ('cnt_invoices','select count(*) from public.invoices'),
        ('cnt_tickets','select count(*) from public.service_tickets'),
        ('cnt_settings','select count(*) from public.settings'),
        ('cnt_profiles','select count(*) from public.profiles'),
        ('cnt_audit','select count(*) from public.audit_log'),
        ('cnt_purchase_orders','select count(*) from public.purchase_orders'),
        ('cnt_suppliers','select count(*) from public.suppliers'),
        ('cnt_notifications','select count(*) from public.notifications')) t(k,sqltext)
    loop
      begin execute q.sqltext into v; exception when others then v := 'ERR '||left(sqlerrm,40); end;
      v_buf := v_buf || jsonb_build_object(q.k, v);
    end loop;
    -- guarded RPCs (each in its own sub-transaction)
    for q in select * from (values
        ('rpc_followup_counts', 'select public.followup_counts()::text'),
        ('rpc_list_followups', 'select count(*)::text from public.list_followups()'),
        ('rpc_assign_lead', format('select public.assign_lead(%L, null, %L)::text', v_lead, 'x')),
        ('rpc_delete_customer', format('select public.delete_customer(%L, %L)::text', v_cust, 'zzz')),
        ('rpc_delete_lead', format('select public.delete_lead(%L)::text', v_lead)),
        ('rpc_mark_po_paid', format('select public.mark_po_paid(%L)::text', v_po)),
        ('rpc_refresh_amc', format('select public.refresh_amc_statuses(%L)::text', v_org)),
        ('rpc_set_std_time', format('select public.set_item_standard_time(%L, %L, %L, 5)::text', v_org, 'product', v_rnd)),
        ('rpc_compute_salary', format('select public.compute_salary(%L, %L, current_date)::text', v_org, v_rnd)),
        ('rpc_create_sale', format('select public.create_sale(%L, %L, %L::jsonb)::text', v_org, v_cust, '{}')),
        ('rpc_sell_amc_plan', format('select public.sell_amc_plan(%L, %L, %L, %L)::text', v_org, v_cust, v_rnd, v_rnd))) t(k,sqltext)
    loop
      -- always undone: a successful call raises the marker below so the fixture is identical for every persona and phase
      begin execute q.sqltext into v; v := 'OK(' || left(coalesce(v,''),20) || ')';
        raise exception 'mx_undo' using errcode = 'P0999';
      exception when sqlstate 'P0999' then null;
                when others then v := 'ERR '||left(sqlerrm,70); end;
      v_buf := v_buf || jsonb_build_object(q.k, v);
    end loop;
    execute 'reset role';
    insert into mx_out select p_phase, p.name, e.key, e.value from jsonb_each_text(v_buf) e;
  end loop;
end
$m$;
select pg_temp.mx_run('before');
