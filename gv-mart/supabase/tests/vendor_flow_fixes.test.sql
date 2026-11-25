-- Tests for 20261213100000_vendor_flow_fixes.sql (build-docs/features/vendor-flow-fixes.md).
-- Run ONLY after that migration has been applied and committed (the 'cancelled' enum value
-- cannot be used in the transaction that adds it). Never concatenate with the migration.
-- Throwaway __TEST_ org only; the final RAISE rolls everything back, nothing persists.
-- Check names start with the acceptance-criterion id they cover (AC1..AC12).
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
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
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid;
  v_sup uuid; v_sup_nonum uuid; v_sup_off uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_other_spare uuid;
  v_po uuid; v_po2 uuid; v_po3 uuid; v_po4 uuid; v_appr uuid; v_bill uuid;
  v_n integer; v_txt text; v_ok boolean; v_paid timestamptz;
begin
  insert into public.organizations (name) values ('__TEST_vendor_flow') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.settings set po_approval_threshold = 1000, po_requires_approval = false,
         wa_test_mode_enabled = false, po_quote_timeout_hours = 24 where org_id = v_org;
  insert into public.organizations (name) values ('__TEST_vendor_flow_other') returning id into v_org2;

  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);

  insert into public.suppliers (org_id, name, whatsapp) values (v_org, '__TEST_ Sup A', '+91 98765 43210') returning id into v_sup;
  insert into public.suppliers (org_id, name, whatsapp) values (v_org, '__TEST_ Sup NoNum', '12345') returning id into v_sup_nonum;
  insert into public.suppliers (org_id, name, whatsapp, is_active) values (v_org, '__TEST_ Sup Off', '9876500001', false) returning id into v_sup_off;

  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ S1', 'T-VF1', 50) returning id into v_s1;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ S2', 'T-VF2', 50) returning id into v_s2;
  insert into public.spares (org_id, name, sku, price) values (v_org, '__TEST_ S3', 'T-VF3', 50) returning id into v_s3;
  insert into public.spares (org_id, name, sku, price) values (v_org2, '__TEST_ Other org spare', 'T-VFX', 50) returning id into v_other_spare;
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_s1, 15, 'warehouse');
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_s1, 15, 'van');
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_s2, 15, 'warehouse');
  insert into public.supplier_products (org_id, supplier_id, item_type, item_id, price) values (v_org, v_sup, 'spare', v_s1, 100);
  insert into public.supplier_products (org_id, supplier_id, item_type, item_id, price) values (v_org, v_sup, 'spare', v_s2, 100);

  -- AC1: over-threshold manual PO stays draft; nothing sent, no payment task, approval + popup notification
  perform pg_temp.as_user(v_ops);
  v_po := public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',20,'price',100)));
  perform pg_temp.as_pg();
  select status::text into v_txt from public.purchase_orders where id = v_po;
  perform pg_temp.chk('AC1 over-threshold PO stays draft', v_txt = 'draft', v_txt);
  perform pg_temp.chk('AC1 over-threshold PO: no WhatsApp queued', not exists (select 1 from public.whatsapp_outbox where ref_id = v_po));
  perform pg_temp.chk('AC1 over-threshold PO: no payment task yet', not exists (select 1 from public.tasks where ref_type = 'purchase_order' and ref_id = v_po));
  select id into v_appr from public.approvals where ref_id = v_po and type = 'po' and status = 'pending';
  perform pg_temp.chk('AC1 over-threshold PO: pending approval created', v_appr is not null);
  perform pg_temp.chk('AC1 over-threshold PO: master popup notification', exists (select 1 from public.notifications where ref_id = v_po and role = 'master' and type = 'po_approval_pending'));

  -- AC1: approve sends it (normalised number) and creates the payment task
  perform pg_temp.as_user(v_master);
  perform public.approve_purchase_order(v_appr);
  perform pg_temp.as_pg();
  select status::text into v_txt from public.purchase_orders where id = v_po;
  perform pg_temp.chk('AC1 approved PO becomes sent', v_txt = 'sent', v_txt);
  perform pg_temp.chk('AC1 approved PO queued to normalised 10-digit number', exists (select 1 from public.whatsapp_outbox where ref_id = v_po and to_mobile = '9876543210'));
  perform pg_temp.chk('AC1 approved PO has payment task', exists (select 1 from public.tasks where ref_type = 'purchase_order' and ref_id = v_po));

  -- AC1: under threshold is sent immediately
  perform pg_temp.as_user(v_ops);
  v_po2 := public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s2,'qty',5,'price',100)));
  perform pg_temp.as_pg();
  select status::text into v_txt from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('AC1 under-threshold PO sent immediately', v_txt = 'sent', v_txt);
  perform pg_temp.chk('AC1 under-threshold PO: no approval', not exists (select 1 from public.approvals where ref_id = v_po2));

  -- AC2: reject cancels the draft and stops blocking auto-reorder
  insert into public.inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'spare', v_s3, 15, 'warehouse');
  insert into public.supplier_products (org_id, supplier_id, item_type, item_id, price) values (v_org, v_sup, 'spare', v_s3, 100);
  insert into public.supplier_products (org_id, supplier_id, item_type, item_id, price) values (v_org, v_sup_off, 'spare', v_s3, 1);
  perform pg_temp.as_user(v_ops);
  v_po3 := public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s3,'qty',50,'price',100)));
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_master);
  update public.approvals set status = 'rejected', approver_id = v_master where ref_id = v_po3 and type = 'po';
  perform pg_temp.as_pg();
  select status::text into v_txt from public.purchase_orders where id = v_po3;
  perform pg_temp.chk('AC2 rejected approval cancels the draft PO', v_txt = 'cancelled', v_txt);
  update public.inventory set stock_qty = 5 where org_id = v_org and item_type = 'spare' and item_id = v_s3 and location = 'warehouse';
  perform pg_temp.chk('AC2 cancelled PO no longer blocks auto-reorder', exists (select 1 from public.purchase_quote_requests where org_id = v_org and item_id = v_s3 and status = 'open'));

  -- AC3: paying before delivery does not block the receipt
  perform pg_temp.as_user(v_master);
  perform public.mark_po_paid(v_po2);
  perform pg_temp.as_pg();
  select status::text, paid_at into v_txt, v_paid from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('AC3 mark paid keeps status sent and sets paid_at', v_txt = 'sent' and v_paid is not null, v_txt);
  perform pg_temp.chk('AC3 mark paid closes the payment task', exists (select 1 from public.tasks where ref_type = 'purchase_order' and ref_id = v_po2 and status = 'done'));
  perform pg_temp.as_user(v_ops);
  v_bill := public.create_bill_entry(v_org, v_sup, v_po2, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s2,'qty',5,'price',100)), 90, date '2026-11-20', null, 'purchase');
  perform pg_temp.as_pg();
  select status::text into v_txt from public.purchase_orders where id = v_po2;
  perform pg_temp.chk('AC3 prepaid PO can be received', v_txt = 'received', v_txt);
  perform pg_temp.chk('AC12 bill_date stored on the bill', (select bill_date from public.purchase_bills where id = v_bill) = date '2026-11-20');

  -- AC3: only master can pay; undo works and reopens the task
  perform pg_temp.as_user(v_ops);
  begin
    perform public.mark_po_paid(v_po);
    perform pg_temp.chk('AC3 ops cannot mark paid', false);
  exception when others then perform pg_temp.chk('AC3 ops cannot mark paid', sqlerrm like '%only master%', sqlerrm); end;
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_master);
  perform public.unmark_po_paid(v_po2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC3 unmark clears paid_at', (select paid_at from public.purchase_orders where id = v_po2) is null);
  perform pg_temp.chk('AC3 unmark reopens the payment task', exists (select 1 from public.tasks where ref_type = 'purchase_order' and ref_id = v_po2 and status = 'open'));

  -- AC4: bill against a PO that is not awaiting receipt is refused (cancelled)
  perform pg_temp.as_user(v_ops);
  begin
    perform public.create_bill_entry(v_org, v_sup, v_po3, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s3,'qty',1,'price',100)), 0, null, null, 'purchase');
    perform pg_temp.chk('AC4 bill against cancelled PO refused', false);
  exception when others then perform pg_temp.chk('AC4 bill against cancelled PO refused', sqlerrm like '%not awaiting receipt%', sqlerrm); end;

  -- AC5: receipt adds stock to the warehouse row only; AC8 partial receipt tracked + alert
  perform public.create_bill_entry(v_org, v_sup, v_po, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',12,'price',100)), 0, null, null, 'purchase');
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC5 receipt adds to warehouse row', (select stock_qty from public.inventory where org_id = v_org and item_id = v_s1 and location = 'warehouse') = 27);
  perform pg_temp.chk('AC5 receipt leaves van row untouched', (select stock_qty from public.inventory where org_id = v_org and item_id = v_s1 and location = 'van') = 15);
  perform pg_temp.chk('AC8 received_qty recorded per line', (select received_qty from public.po_items where po_id = v_po) = 12);
  perform pg_temp.chk('AC8 short receipt raises an alert', exists (select 1 from public.notifications where ref_id = v_po and type = 'po_received_short'));

  -- AC6: van stock falling below min does not open a supplier quote request
  update public.inventory set stock_qty = 1 where org_id = v_org and item_id = v_s1 and location = 'van';
  perform pg_temp.chk('AC6 van low stock opens no quote request', not exists (select 1 from public.purchase_quote_requests where org_id = v_org and item_id = v_s1));

  -- AC7: input validation
  perform pg_temp.as_user(v_ops);
  begin
    perform public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',0)));
    perform pg_temp.chk('AC7 PO with price 0 refused', false);
  exception when others then perform pg_temp.chk('AC7 PO with price 0 refused', sqlerrm like '%price above zero%', sqlerrm); end;
  begin
    perform public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_other_spare,'qty',1,'price',10)));
    perform pg_temp.chk('AC7 PO with another org''s item refused', false);
  exception when others then perform pg_temp.chk('AC7 PO with another org''s item refused', sqlerrm like '%item not found%', sqlerrm); end;
  begin
    perform public.create_purchase_order(v_org, v_sup_off, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)));
    perform pg_temp.chk('AC9 PO to inactive supplier refused', false);
  exception when others then perform pg_temp.chk('AC9 PO to inactive supplier refused', sqlerrm like '%inactive%', sqlerrm); end;
  begin
    perform public.create_bill_entry(v_org, v_sup, null, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)), -5, null, null, 'purchase');
    perform pg_temp.chk('AC7 negative GST refused', false);
  exception when others then perform pg_temp.chk('AC7 negative GST refused', sqlerrm like '%GST cannot be negative%', sqlerrm); end;
  begin
    perform public.create_bill_entry(v_org, v_sup, null, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',0,'price',10)), 0, null, null, 'purchase');
    perform pg_temp.chk('AC8 all-zero receipt refused', false);
  exception when others then perform pg_temp.chk('AC8 all-zero receipt refused', sqlerrm like '%at least one item%', sqlerrm); end;
  begin
    perform public.create_bill_entry(v_org, v_sup, null, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)), 0, null, v_org2::text || '/x.jpg', 'purchase');
    perform pg_temp.chk('AC12 bill photo outside own org folder refused', false);
  exception when others then perform pg_temp.chk('AC12 bill photo outside own org folder refused', sqlerrm like '%organisation''s folder%', sqlerrm); end;

  -- AC4: PO must belong to the billed supplier
  v_po4 := public.create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)));
  begin
    perform public.create_bill_entry(v_org, v_sup_nonum, v_po4, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)), 0, null, null, 'purchase');
    perform pg_temp.chk('AC4 bill against another supplier''s PO refused', false);
  exception when others then perform pg_temp.chk('AC4 bill against another supplier''s PO refused', sqlerrm like '%different supplier%', sqlerrm); end;

  -- AC10: supplier without a valid number -> no outbox row, admin alert
  v_po4 := public.create_purchase_order(v_org, v_sup_nonum, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_s1,'qty',1,'price',10)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC10 no-number supplier: nothing queued', not exists (select 1 from public.whatsapp_outbox where ref_id = v_po4));
  perform pg_temp.chk('AC10 no-number supplier: admin alerted', exists (select 1 from public.notifications where ref_id = v_po4 and type = 'po_not_messaged'));

  -- AC10: WhatsApp test mode blocks auto supplier messages that are not allow-listed
  update public.settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = '{}' where org_id = v_org;
  update public.inventory set stock_qty = 15 where org_id = v_org and item_id = v_s2 and location = 'warehouse';
  update public.inventory set stock_qty = 2 where org_id = v_org and item_id = v_s2 and location = 'warehouse';
  select count(*) into v_n from public.whatsapp_outbox o join public.purchase_quote_requests q on q.id = o.ref_id where q.org_id = v_org and q.item_id = v_s2;
  perform pg_temp.chk('AC10 test mode: quote request not queued to a non-allow-listed supplier', v_n = 0, v_n::text);
  perform pg_temp.chk('AC10 test mode: block is audited', exists (select 1 from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED' and after ->> 'via' = '_queue_supplier_whatsapp'));

  -- AC9: inactive supplier is not invited
  perform pg_temp.chk('AC9 inactive supplier not invited', not exists (select 1 from public.whatsapp_outbox where to_mobile = '9876500001'));

  -- AC11: duplicate supplier-item link refused
  begin
    insert into public.supplier_products (org_id, supplier_id, item_type, item_id, price) values (v_org, v_sup, 'spare', v_s1, 90);
    perform pg_temp.chk('AC11 duplicate supplier-item link refused', false);
  exception when unique_violation then perform pg_temp.chk('AC11 duplicate supplier-item link refused', true); end;

  -- Grants: helpers are not callable by app roles; unmark is
  perform pg_temp.chk('GRANT anon cannot run unmark_po_paid', not has_function_privilege('anon', 'public.unmark_po_paid(uuid)', 'execute'));
  perform pg_temp.chk('GRANT authenticated can run unmark_po_paid', has_function_privilege('authenticated', 'public.unmark_po_paid(uuid)', 'execute'));
  perform pg_temp.chk('GRANT authenticated cannot run _queue_supplier_whatsapp', not has_function_privilege('authenticated', 'public._queue_supplier_whatsapp(uuid,uuid,text,text,text,jsonb,text,uuid)', 'execute'));
  perform pg_temp.chk('GRANT anon cannot run _queue_supplier_whatsapp', not has_function_privilege('anon', 'public._queue_supplier_whatsapp(uuid,uuid,text,text,text,jsonb,text,uuid)', 'execute'));
  perform pg_temp.chk('GRANT anon cannot run create_bill_entry', not has_function_privilege('anon', 'public.create_bill_entry(uuid,uuid,uuid,jsonb,numeric,date,text,expense_category)', 'execute'));
end
$t$;

do $r$ begin
  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $r$;
