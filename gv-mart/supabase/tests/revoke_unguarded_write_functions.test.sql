-- Rolled-back test for migrations/20261015120000_revoke_unguarded_write_functions.sql.
-- Runner (one transaction, ends in RAISE): the migration file, then this block. Throwaway __TEST_ data only.
do $t$
declare
  res text := ''; v_org uuid; v_m uuid := gen_random_uuid(); v_cust uuid; v_sup uuid; v_sp uuid; v_po uuid; n int; r record; v jsonb;
begin
  insert into organizations(name) values ('__TEST_revoke_fn') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into auth.users(id,email) values (v_m,'__test_'||v_m||'@example.invalid');
  insert into profiles(id,org_id,full_name,role) values (v_m,v_org,'__TEST_master','master');
  insert into customers(org_id,name,mobile) values (v_org,'__TEST_cust','9000000001') returning id into v_cust;
  insert into suppliers(org_id,name,whatsapp) values (v_org,'__TEST_sup','9000000099') returning id into v_sup;
  insert into spares(org_id,name,price) values (v_org,'__TEST_spare',10) returning id into v_sp;
  insert into inventory(org_id,item_type,item_id,location,stock_qty) values (v_org,'spare',v_sp,'warehouse',5);

  -- ===== ACLs: every overload =====
  for r in select p.oid::regprocedure as sig, p.proname from pg_proc p where p.pronamespace='public'::regnamespace
            and p.proname in ('_auto_assign_ticket_internal','_sale_create_line_invoice','_create_po_payment_reminder_task',
              '_resolve_purchase_quote_requests_core','wa_resolve_purchase_quote_requests','advance_recurring_tasks',
              'open_monthly_quote_requests','run_rental_billing','wa_escalate_overdue_po_payment_reminders','_create_po_from_winning_quote')
  loop
    res := res || E'\n' || case when not has_function_privilege('anon', r.sig, 'execute')
                                  and not has_function_privilege('authenticated', r.sig, 'execute')
                                  and has_function_privilege('service_role', r.sig, 'execute')
                           then 'ok   ACL '||r.proname||': anon no, authenticated no, service_role yes'
                           else 'FAIL ACL '||r.proname end;
  end loop;
  select count(*) into n from pg_proc p where p.pronamespace='public'::regnamespace
     and p.proname in ('_auto_assign_ticket_internal','_sale_create_line_invoice','_create_po_payment_reminder_task',
              '_resolve_purchase_quote_requests_core','wa_resolve_purchase_quote_requests','advance_recurring_tasks',
              'open_monthly_quote_requests','run_rental_billing','wa_escalate_overdue_po_payment_reminders','_create_po_from_winning_quote');
  res := res || E'\n' || case when n=10 then 'ok   ACL covered 10 functions' else 'FAIL ACL function count '||n end;

  -- ===== a real call as anon and as a signed-in master is refused by privilege =====
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin perform run_rental_billing(v_org); res := res || E'\nFAIL A1 anon ran run_rental_billing';
  exception when insufficient_privilege then res := res || E'\nok   A1 anon: run_rental_billing permission denied'; when others then res := res || E'\nFAIL A1 '||sqlerrm; end;
  begin perform advance_recurring_tasks(v_org); res := res || E'\nFAIL A2';
  exception when insufficient_privilege then res := res || E'\nok   A2 anon: advance_recurring_tasks permission denied'; when others then res := res || E'\nFAIL A2 '||sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform run_rental_billing(v_org); res := res || E'\nFAIL A3 authenticated master ran it';
  exception when insufficient_privilege then res := res || E'\nok   A3 authenticated master: run_rental_billing permission denied'; when others then res := res || E'\nFAIL A3 '||sqlerrm; end;
  begin perform open_monthly_quote_requests(v_org); res := res || E'\nFAIL A4';
  exception when insufficient_privilege then res := res || E'\nok   A4 authenticated: open_monthly_quote_requests permission denied'; when others then res := res || E'\nFAIL A4 '||sqlerrm; end;
  execute 'reset role';

  -- ===== service_role (Edge Functions) still can =====
  perform set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  execute 'set local role service_role';
  begin n := run_rental_billing(v_org); res := res || E'\nok   S1 service_role: run_rental_billing -> '||n;
  exception when others then res := res || E'\nFAIL S1 '||sqlerrm; end;
  begin n := advance_recurring_tasks(v_org); res := res || E'\nok   S2 service_role: advance_recurring_tasks -> '||n;
  exception when others then res := res || E'\nFAIL S2 '||sqlerrm; end;
  begin n := wa_resolve_purchase_quote_requests(v_org); res := res || E'\nok   S3 service_role: wa_resolve_purchase_quote_requests -> '||n;
  exception when others then res := res || E'\nFAIL S3 '||sqlerrm; end;
  begin n := wa_escalate_overdue_po_payment_reminders(v_org); res := res || E'\nok   S4 service_role: wa_escalate_overdue_po_payment_reminders -> '||n;
  exception when others then res := res || E'\nFAIL S4 '||sqlerrm; end;
  begin n := open_monthly_quote_requests(v_org); res := res || E'\nok   S5 service_role: open_monthly_quote_requests -> '||n;
  exception when others then res := res || E'\nFAIL S5 '||sqlerrm; end;
  execute 'reset role';

  -- ===== real callers keep working as the signed-in master =====
  perform set_config('request.jwt.claims', json_build_object('sub',v_m,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    v_po := create_purchase_order(v_org, v_sup, jsonb_build_array(jsonb_build_object('item_type','spare','item_id',v_sp,'qty',2,'price',10)));
    select count(*) into n from tasks where ref_type='purchase_order' and ref_id=v_po;
    res := res || E'\n' || case when n=1 then 'ok   P1 create_purchase_order (now definer) still creates the PO and its payment-reminder task' else 'FAIL P1 tasks='||n end;
    select count(*) into n from whatsapp_outbox where ref_type='purchase_order' and ref_id=v_po and sent_by=v_m;
    res := res || E'\n' || case when n=1 then 'ok   P2 ... and queues the supplier message through send_staff_whatsapp with the master as sender' else 'FAIL P2 outbox='||n end;
  exception when others then res := res || E'\nFAIL P1 '||sqlerrm; end;
  begin perform create_purchase_order(v_org, v_sup, '[]'::jsonb); res := res || E'\nFAIL P3 empty items accepted';
  exception when others then res := res || E'\nok   P3 create_purchase_order still validates: '||sqlerrm; end;
  begin n := resolve_purchase_quote_requests(v_org); res := res || E'\nok   P4 resolve_purchase_quote_requests (definer, calls the revoked core) works as master -> '||n;
  exception when others then res := res || E'\nFAIL P4 '||sqlerrm; end;
  begin
    v := create_sale(v_org, v_cust, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_sp, 'qty', 1)), 'payment_method', 'cash'));
    res := res || E'\nok   P5 create_sale (calls the revoked _sale_create_line_invoice) works as master';
  exception when others then res := res || E'\nINFO P5 create_sale: '||left(sqlerrm,120); end;
  execute 'reset role';
  raise exception E'RESULTS:%', res;
end
$t$;
