-- DB tests for 20270103100000_quotation_edit_discount (spec build-docs/features/quotation-edit-discount.md).
-- Run ONLY after the migration, in one request. Ends in an unconditional RAISE, so everything rolls back.
-- Throwaway __TEST_ organisation only. NOT RUN YET: needs the owner to name it.
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
  v_org uuid; v_master uuid; v_c1 uuid; v_c2 uuid;
  v_brand uuid; v_model uuid; v_prod uuid; v_spare uuid;
  v_q uuid; v_q2 uuid; v_lead uuid; r jsonb; inv invoices; q quotations; n int; v_err text;
begin
  -- ---------- setup: throwaway org, 18% extra, 10% discount cap ----------
  insert into organizations (name) values ('__TEST_quotation_edit') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update settings set gst_rate = 18, prices_include_gst = false, discount_admin_max = 10, discount_tech_max = 10 where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ qed c1', '5550400001') returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ qed c2', '5550400002') returning id into v_c2;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into inventory (org_id, item_type, item_id, stock_qty, location) values (v_org, 'product', v_prod, 10, 'warehouse');
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 500) returning id into v_spare;
  insert into inventory (org_id, item_type, item_id, location, stock_qty) values (v_org, 'spare', v_spare, 'warehouse', 10);

  -- ---------- signatures / ACLs ----------
  perform pg_temp.chk('one overload each: create_quotation, update_quotation, _sale_create_line_invoice',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('create_quotation', 'update_quotation', '_sale_create_line_invoice')) = 3);
  perform pg_temp.chk('update_quotation + create_quotation: authenticated yes, anon no',
    (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
       from pg_proc p where pronamespace = 'public'::regnamespace and proname in ('create_quotation', 'update_quotation')));
  perform pg_temp.chk('_quoted_price / _sale_create_line_invoice not callable by authenticated or anon',
    (select bool_and(not has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
       from pg_proc p where pronamespace = 'public'::regnamespace and proname in ('_quoted_price', '_sale_create_line_invoice')));
  perform pg_temp.chk('AC6 old quotations: discount_amount defaults to 0',
    not exists (select 1 from quotations where discount_amount <> 0 and org_id <> v_org));

  -- ---------- AC1 direct quotation -> new lead, quoted, follow-up booked ----------
  perform pg_temp.as_user(v_master);
  v_q := public.create_quotation(v_org, v_c1, current_date + 7,
           jsonb_build_array(jsonb_build_object('item_type', 'product', 'item_id', v_prod, 'qty', 2)), null, null, null, 1000, 'festival offer');
  perform pg_temp.as_pg();
  select * into q from quotations where id = v_q;
  select id into v_lead from leads where id = q.lead_id;
  perform pg_temp.chk('AC1 direct quote creates a lead from the customer (source direct_quotation, status quoted)',
    (select l.customer_id = v_c1 and l.source = 'direct_quotation' and l.status::text = 'quoted' and l.mobile = '5550400001' from leads l where l.id = v_lead));
  perform pg_temp.chk('AC1 lead has a quotation_created note and an open follow-up (Daily Follow Up)',
    exists (select 1 from lead_activities where lead_id = v_lead and type = 'quotation_created')
    and exists (select 1 from lead_followups where lead_id = v_lead and status = 'open'));
  perform pg_temp.chk('AC1 lead is assigned to the staff member who made the quote',
    (select assigned_to from leads where id = v_lead) = v_master);
  perform pg_temp.chk('AC2 create with ₹1000 discount: total net 19000, discount + reason stored',
    q.total = 19000 and q.discount_amount = 1000 and q.discount_reason = 'festival offer', format('%s/%s', q.total, q.discount_amount));

  -- ---------- AC4 discount cap + reason, on create ----------
  begin
    perform pg_temp.as_user(v_master);
    perform public.create_quotation(v_org, v_c2, null, jsonb_build_array(jsonb_build_object('item_type', 'product', 'item_id', v_prod, 'qty', 1)), null, null, null, 1001, 'too much');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC4 create: discount over 10% refused', v_err like '%percent of the subtotal%', v_err);
  begin
    perform pg_temp.as_user(v_master);
    perform public.create_quotation(v_org, v_c2, null, jsonb_build_array(jsonb_build_object('item_type', 'product', 'item_id', v_prod, 'qty', 1)), null, null, null, 100, '  ');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC4 create: discount without a reason refused', v_err like '%needs a reason%', v_err);

  -- ---------- AC2 edit an open quote: qty, new item, discount, history; quoted price kept ----------
  update products set price = 11000 where id = v_prod; -- master price rises after quoting
  perform pg_temp.as_user(v_master);
  perform public.update_quotation(v_q,
    jsonb_build_array(jsonb_build_object('item_type', 'product', 'item_id', v_prod, 'qty', 3),
                      jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 2)),
    2000, 'bulk order', current_date + 14, 'customer wants 3 units');
  perform pg_temp.as_pg();
  select * into q from quotations where id = v_q;
  perform pg_temp.chk('AC2 edit: product keeps quoted 10000 (not new 11000), spare added at 500, total 3*10000+2*500-2000 = 29000',
    q.total = 29000 and q.discount_amount = 2000 and q.valid_until = current_date + 14
    and (select price from quotation_items where quotation_id = v_q and item_id = v_prod) = 10000,
    format('%s', q.total));
  perform pg_temp.chk('AC2 edit history row: 19000 -> 29000, discount 1000 -> 2000, reason, items before/after',
    (select count(*) = 1 and bool_and(old_total = 19000 and new_total = 29000 and old_discount = 1000 and new_discount = 2000
            and reason = 'customer wants 3 units' and jsonb_array_length(items_before) = 1 and jsonb_array_length(items_after) = 2)
       from quotation_revisions where quotation_id = v_q));

  begin
    perform pg_temp.as_user(v_master);
    perform public.update_quotation(v_q, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)), 0, null, null, '');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC2 edit without a reason refused', v_err like '%reason for the change%', v_err);

  -- ---------- AC5 convert: quoted prices billed even after the master price rose ----------
  perform pg_temp.as_user(v_master);
  r := public.create_sale(v_org, v_c1, jsonb_build_object(
         'product_items', jsonb_build_array(jsonb_build_object('item_id', v_prod, 'qty', 3)),
         'spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 2)),
         'amc', null, 'discount_percent', 6.45, 'payment_method', 'cash'), v_q);
  perform pg_temp.as_pg();
  select * into inv from invoices where id = (r ->> 'product_invoice_id')::uuid;
  perform pg_temp.chk('AC5 product invoice billed at quoted 10000 x 3 = 30000 (master is now 11000)',
    inv.subtotal = 30000 and (select price from invoice_items where invoice_id = inv.id) = 10000, format('%s', inv.subtotal));
  perform pg_temp.chk('AC5 quotation marked converted', (select status::text from quotations where id = v_q) = 'converted');

  -- ---------- AC3 locked after conversion ----------
  begin
    perform pg_temp.as_user(v_master);
    perform public.update_quotation(v_q, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)), 0, null, null, 'late change');
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC3 update_quotation refuses a converted quote', v_err like '%only open quotations%', v_err);
  begin
    perform pg_temp.as_user(v_master);
    update quotation_items set qty = 99 where quotation_id = v_q;
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC3 trigger refuses a direct item edit on a converted quote', v_err like '%no longer open%', v_err);
  begin
    perform pg_temp.as_user(v_master);
    r := public.create_sale(v_org, v_c1, jsonb_build_object('spare_items', jsonb_build_array(jsonb_build_object('item_id', v_spare, 'qty', 1)),
           'product_items', '[]'::jsonb, 'amc', null, 'discount_percent', 0, 'payment_method', 'cash'), v_q);
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC3 a converted quote cannot be converted again', v_err like '%is not open%', v_err);

  -- ---------- lead-linked quote does NOT create another lead; lost quote is locked ----------
  select count(*) into n from leads where org_id = v_org;
  perform pg_temp.as_user(v_master);
  v_q2 := public.create_quotation(v_org, v_c1, null, jsonb_build_array(jsonb_build_object('item_type', 'spare', 'item_id', v_spare, 'qty', 1)), v_lead);
  perform pg_temp.as_pg();
  perform pg_temp.chk('quote from an existing lead creates no new lead', (select count(*) from leads where org_id = v_org) = n
    and (select lead_id from quotations where id = v_q2) = v_lead);
  update quotations set status = 'lost', lost_reason = 'price' where id = v_q2;
  begin
    update quotations set total = 1 where id = v_q2;
    v_err := 'no error';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('AC3 lost quote: amount can no longer change', v_err like '%can no longer change%', v_err);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
