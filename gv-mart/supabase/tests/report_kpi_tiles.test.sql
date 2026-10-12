-- Rolled-back DB tests for report_kpi_tiles (docs/plan-kpi-tiles.md, Step 2).
-- Run with the migration text concatenated in front of this file (supabase/migrations/*report_kpi_tiles.sql is idempotent).
-- Everything runs in two throwaway "__TEST_" organisations and ends in a RAISE, so nothing is kept and no purge is needed.
-- Expected values are hand-computed; the arithmetic is in the comments next to each fixture.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__T ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
-- call the function as a user; an error comes back as {"error": "..."} so tests can assert on it
create function pg_temp.kpi(p_uid uuid, p_from date, p_to date) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_user(p_uid);
  begin r := public.report_kpi_tiles(p_from, p_to);
  exception when others then r := jsonb_build_object('error', sqlerrm); end;
  perform pg_temp.as_pg();
  return r;
end $f$;
create function pg_temp.n(r jsonb, p text[]) returns numeric language sql as $f$ select (r #>> p)::numeric $f$;
create function pg_temp.mkorg(p_tag text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.organizations (name) values ('__TEST_kpi_' || p_tag || '_' || gen_random_uuid()) returning id into v;
  insert into public.settings (org_id) values (v) on conflict do nothing;
  return v;
end $f$;
create function pg_temp.mkcust(p_org uuid, p_name text, p_test boolean default false) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into public.customers (id, org_id, name, mobile, is_test) values (v, p_org, p_name, lpad(abs(hashtext(v::text)::bigint)::text, 10, '0'), p_test);
  return v;
end $f$;
create function pg_temp.mkinv(p_org uuid, p_cust uuid, p_type text, p_gst numeric, p_total numeric, p_paid numeric, p_at timestamptz) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at, updated_at)
  values (p_org, p_cust, p_type::public.invoice_type, p_total - p_gst, 0, p_gst, p_total, public._derive_payment_status(p_paid, p_total), p_paid, p_at, p_at)
  returning id into v;
  return v;
end $f$;
create function pg_temp.mkitem(p_org uuid, p_inv uuid, p_type text, p_item uuid, p_qty int, p_price numeric, p_discount numeric, p_cost numeric, p_at timestamptz) returns void language plpgsql as $f$
begin
  insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost, created_at, updated_at)
  values (p_org, p_inv, p_type::public.item_type, p_item, p_qty, p_price, p_discount, p_cost, p_at, p_at);
end $f$;
create function pg_temp.mkticket(p_org uuid, p_cust uuid, p_inv uuid, p_status text, p_prio text, p_sla timestamptz, p_created timestamptz, p_updated timestamptz) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.service_tickets (org_id, customer_id, type, invoice_id, status, priority, sla_due_at, created_at, updated_at)
  values (p_org, p_cust, 'paid', p_inv, p_status::public.ticket_status, p_prio::public.priority_level, p_sla, p_created, p_updated) returning id into v;
  return v;
end $f$;
create function pg_temp.mkvisit(p_org uuid, p_ticket uuid, p_tech uuid, p_start timestamptz, p_charge numeric) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, service_charge, created_at, updated_at)
  values (p_org, p_ticket, p_tech, p_start, p_charge, p_start, p_start) returning id into v;
  return v;
end $f$;

do $t$
declare
  txt text;
  o uuid; o2 uuid;
  m uuid; opa uuid; sa uuid; tcu uuid; cu uuid; ina uuid; m2 uuid;
  tech uuid; brand uuid; model uuid; prodX uuid; prodY uuid; spareS uuid; plan uuid;
  cA uuid; cB uuid; cC uuid; cD uuid; cT uuid; cX uuid; cX2 uuid;
  i1 uuid; i2 uuid; i3 uuid; i4 uuid; i5 uuid; i6 uuid; iT uuid; iX uuid;
  tk6 uuid; tkL uuid; tkT uuid; tkX uuid; v6 uuid; vL uuid; vL2 uuid; vT uuid; vX uuid;
  r jsonb; r0 jsonb; r1 jsonb; r2 jsonb; pnl jsonb; ss jsonb; fun jsonb; opr jsonb; fb jsonb; cust_tot jsonb;
  fp1 text; fp2 text; ea text;
  mob text;
  n_before int;
begin
  -- real-data fingerprints (everything outside __TEST_ organisations)
  select md5(coalesce(string_agg(id::text || total::text || amount_paid::text, ',' order by id), '')) into fp1 from public.invoices
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  o := pg_temp.mkorg('a');
  if (select name from organizations where id = o) not like '\_\_TEST\_%' then raise exception 'refusing to run outside a __TEST_ org'; end if;
  o2 := pg_temp.mkorg('b');
  m := pg_temp.mkuser('master', o);
  opa := pg_temp.mkuser('operation_admin', o);
  sa := pg_temp.mkuser('sales_admin', o);
  tcu := pg_temp.mkuser('technician', o);
  cu := pg_temp.mkuser('customer', o);
  ina := pg_temp.mkuser('sales_admin', o);
  update public.profiles set is_active = false where id = ina;
  m2 := pg_temp.mkuser('master', o2);
  insert into public.technicians (org_id, profile_id) values (o, tcu) returning id into tech;

  cA := pg_temp.mkcust(o, 'Alpha'); cB := pg_temp.mkcust(o, 'Bravo'); cC := pg_temp.mkcust(o, 'Charlie'); cD := pg_temp.mkcust(o, 'Delta');
  cT := pg_temp.mkcust(o, 'Flagged', true);          -- is_test customer: no rows yet, they are added later for the byte-identical check

  insert into public.brands (org_id, name, category) values (o, '__T brand', 'ro') returning id into brand;
  insert into public.models (org_id, brand_id, name) values (o, brand, '__T model') returning id into model;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'Product X', 'ro', 5250) returning id into prodX;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'Product Y', 'ro', 5000) returning id into prodY;
  insert into public.spares (org_id, name, price) values (o, 'Spare S', 250) returning id into spareS;
  insert into public.amc_plans (org_id, name, years, price) values (o, '__T plan', 1, 1000) returning id into plan;

  -- ===== ORG A, Oct 2026 (explicit IST instants) =====
  -- i1 product 11,210 (GST 1,710) paid 11,210; item product qty 2 @5,250 disc 1,000 cost 3,500 -> line revenue 9,500, cost 7,000
  i1 := pg_temp.mkinv(o, cA, 'product', 1710, 11210, 11210, timestamptz '2026-10-05 12:00:00+05:30');
  perform pg_temp.mkitem(o, i1, 'product', prodX, 2, 5250, 1000, 3500, timestamptz '2026-10-05 12:00:00+05:30');
  -- i2 product 5,900 (GST 900) paid 2,000; item product qty 1 @5,000 cost NULL (cost missing) -> line revenue 5,000
  i2 := pg_temp.mkinv(o, cB, 'product', 900, 5900, 2000, timestamptz '2026-10-06 12:00:00+05:30');
  perform pg_temp.mkitem(o, i2, 'product', prodY, 1, 5000, 0, null, timestamptz '2026-10-06 12:00:00+05:30');
  -- i3 AMC 2,360 (360) paid; i4 rent 590 (90) paid
  i3 := pg_temp.mkinv(o, cA, 'amc', 360, 2360, 2360, timestamptz '2026-10-07 12:00:00+05:30');
  i4 := pg_temp.mkinv(o, cB, 'rent', 90, 590, 590, timestamptz '2026-10-08 12:00:00+05:30');
  -- i5 counter spare sale 1,180 (180) DUE (paid 0); item spare qty 4 @250 cost 100 -> revenue 1,000, cost 400
  i5 := pg_temp.mkinv(o, cC, 'spare', 180, 1180, 0, timestamptz '2026-10-09 12:00:00+05:30');
  perform pg_temp.mkitem(o, i5, 'spare', spareS, 4, 250, 0, 100, timestamptz '2026-10-09 12:00:00+05:30');
  -- i6 service invoice (spare type, linked to a ticket with a visit) 1,062 (162) paid; item spare qty 2 @250 disc 50 cost 100 -> revenue 450, cost 200
  i6 := pg_temp.mkinv(o, cD, 'spare', 162, 1062, 1062, timestamptz '2026-10-10 12:00:00+05:30');
  perform pg_temp.mkitem(o, i6, 'spare', spareS, 2, 250, 50, 100, timestamptz '2026-10-10 12:00:00+05:30');
  -- boundary invoices (product, no items): Oct 1 00:30 IST 118 paid; Oct 31 23:50 IST 236 paid; Sep 30 23:50 IST 354 DUE; Nov 1 00:30 IST 472 DUE
  perform pg_temp.mkinv(o, cA, 'product', 18, 118, 118, timestamptz '2026-10-01 00:30:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 36, 236, 236, timestamptz '2026-10-31 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 54, 354, 0, timestamptz '2026-09-30 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 72, 472, 0, timestamptz '2026-11-01 00:30:00+05:30');
  -- expenses: in Oct purchase 4,000 / salary 6,000 / rent 3,000 / electricity 500 / ad_campaign 700 = 14,200 (excl. purchase 10,200); outside: Sep 30 purchase 9,999, Nov 1 salary 8,888
  insert into public.expenses (org_id, category, amount, date) values
    (o, 'purchase', 4000, date '2026-10-05'), (o, 'salary', 6000, date '2026-10-31'), (o, 'rent', 3000, date '2026-10-01'),
    (o, 'electricity', 500, date '2026-10-15'), (o, 'ad_campaign', 700, date '2026-10-20'),
    (o, 'purchase', 9999, date '2026-09-30'), (o, 'salary', 8888, date '2026-11-01');
  -- leads created in Oct: new/field, contacted/field, won/whatsapp, won/walk_in, lost/field (+ one won on Sep 30, outside)
  insert into public.leads (org_id, name, source, status, created_at) values
    (o, '__T L1', 'field', 'new', timestamptz '2026-10-02 10:00:00+05:30'),
    (o, '__T L2', 'field', 'contacted', timestamptz '2026-10-03 10:00:00+05:30'),
    (o, '__T L3', 'whatsapp', 'won', timestamptz '2026-10-04 10:00:00+05:30'),
    (o, '__T L4', 'walk_in', 'won', timestamptz '2026-10-05 10:00:00+05:30'),
    (o, '__T L5', 'field', 'lost', timestamptz '2026-10-06 10:00:00+05:30'),
    (o, '__T L0', 'field', 'won', timestamptz '2026-09-30 10:00:00+05:30');
  -- tickets: tk6 (service invoice i6) completed within 24h; tkL completed after 3 days; open normal (cB); assigned urgent past SLA (cC);
  -- in_progress very_urgent (cD); one cancelled (cA, never counted)
  tk6 := pg_temp.mkticket(o, cD, i6, 'completed', 'normal', null, timestamptz '2026-10-10 10:00:00+05:30', timestamptz '2026-10-10 15:00:00+05:30');
  tkL := pg_temp.mkticket(o, cB, null, 'completed', 'normal', null, timestamptz '2026-10-11 10:00:00+05:30', timestamptz '2026-10-14 10:00:00+05:30');
  perform pg_temp.mkticket(o, cB, null, 'open', 'normal', null, timestamptz '2026-10-12 10:00:00+05:30', timestamptz '2026-10-12 10:00:00+05:30');
  perform pg_temp.mkticket(o, cC, null, 'assigned', 'urgent', now() - interval '1 day', timestamptz '2026-10-12 11:00:00+05:30', timestamptz '2026-10-12 11:00:00+05:30');
  perform pg_temp.mkticket(o, cD, null, 'in_progress', 'very_urgent', now() + interval '3 days', timestamptz '2026-10-12 12:00:00+05:30', timestamptz '2026-10-12 12:00:00+05:30');
  perform pg_temp.mkticket(o, cA, null, 'cancelled', 'normal', null, timestamptz '2026-10-12 13:00:00+05:30', timestamptz '2026-10-12 13:00:00+05:30');
  -- ratings via visits: tk6 visit 5, tkL visit 4, second tkL visit 3  -> average 4.0, count 3, below 4.5 = 2
  v6 := pg_temp.mkvisit(o, tk6, tech, timestamptz '2026-10-10 11:00:00+05:30', 500);
  vL := pg_temp.mkvisit(o, tkL, tech, timestamptz '2026-10-11 11:00:00+05:30', 0);
  vL2 := pg_temp.mkvisit(o, tkL, tech, timestamptz '2026-10-12 11:00:00+05:30', 0);
  insert into public.ratings (org_id, visit_id, stars, created_at) values
    (o, v6, 5, timestamptz '2026-10-10 12:00:00+05:30'), (o, vL, 4, timestamptz '2026-10-11 12:00:00+05:30'), (o, vL2, 3, timestamptz '2026-10-12 12:00:00+05:30');
  -- AMC: active due_soon (cA), active (cB), expired (cC), cancelled (cD)  -> active 2, renewal_window 1
  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values
    (o, cA, prodX, plan, current_date - 300, current_date + 20, 'due_soon'),
    (o, cB, prodX, plan, current_date - 30, current_date + 300, 'active'),
    (o, cC, prodX, plan, current_date - 400, current_date - 10, 'expired');
  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, cancelled_at, cancel_reason) values
    (o, cD, prodX, plan, current_date - 30, current_date + 300, 'active', now(), '__T cancelled');

  -- ===== hand-computed values, master of org A, window 2026-10-01 .. 2026-10-31 =====
  r := pg_temp.kpi(m, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('master gets all three groups', jsonb_typeof(r->'sales') = 'object' and jsonb_typeof(r->'service') = 'object' and jsonb_typeof(r->'money_out') = 'object' and r->>'role' = 'master', left(r::text, 120));
  -- invoiced: 11,210+5,900+2,360+590+1,180+1,062+118+236 = 22,656; GST 1,710+900+360+90+180+162+18+36 = 3,456; net 19,200; 8 invoices
  perform pg_temp.chk('t1 invoiced total 22,656 / gst 3,456 / net 19,200 / 8 invoices',
    pg_temp.n(r,'{sales,invoiced,total}')=22656 and pg_temp.n(r,'{sales,invoiced,gst}')=3456 and pg_temp.n(r,'{sales,invoiced,net}')=19200 and pg_temp.n(r,'{sales,invoiced,count}')=8, (r->'sales'->'invoiced')::text);
  -- collected: 11,210+2,000+2,360+590+0+1,062+118+236 = 17,576; GST share 1,710+305.08+360+90+0+162+18+36 = 2,681.08; net 14,894.92
  perform pg_temp.chk('t2 collected total 17,576 / net 14,894.92', pg_temp.n(r,'{sales,collected,total}')=17576 and pg_temp.n(r,'{sales,collected,net}')=14894.92, (r->'sales'->'collected')::text);
  -- outstanding (live, all dates): i2 3,900 + i5 1,180 + Sep 354 + Nov 472 = 5,906, 4 invoices, oldest 2026-09-30
  perform pg_temp.chk('t3 outstanding 5,906 over 4 invoices, oldest 2026-09-30',
    pg_temp.n(r,'{sales,outstanding,amount}')=5906 and pg_temp.n(r,'{sales,outstanding,invoice_count}')=4 and r #>> '{sales,outstanding,oldest_invoice_date}' = '2026-09-30', (r->'sales'->'outstanding')::text);
  -- streams: class sales = 11,210+5,900+1,180+118+236 = 18,644 = product lines 14,500 + spare lines 1,000 + remainder 3,144; service 1,062; amc 2,360; rental 590
  perform pg_temp.chk('t7 streams product 14,500 / spare 1,000 / gst+adj 3,144 / service 1,062 / amc 2,360 / rental 590',
    pg_temp.n(r,'{sales,streams,product}')=14500 and pg_temp.n(r,'{sales,streams,spare_counter}')=1000 and pg_temp.n(r,'{sales,streams,gst_and_adjustments}')=3144
    and pg_temp.n(r,'{sales,streams,service}')=1062 and pg_temp.n(r,'{sales,streams,amc}')=2360 and pg_temp.n(r,'{sales,streams,rental}')=590, (r->'sales'->'streams')::text);
  perform pg_temp.chk('t7 streams add up to invoiced total (22,656)',
    pg_temp.n(r,'{sales,streams,product}')+pg_temp.n(r,'{sales,streams,spare_counter}')+pg_temp.n(r,'{sales,streams,gst_and_adjustments}')+pg_temp.n(r,'{sales,streams,service}')+pg_temp.n(r,'{sales,streams,amc}')+pg_temp.n(r,'{sales,streams,rental}') = pg_temp.n(r,'{sales,invoiced,total}'));
  perform pg_temp.chk('t7 the stream note says spares used on a service visit count as Service', r #>> '{sales,streams,note}' like '%service visit count as Service%');
  perform pg_temp.chk('t8 units sold 3, average sale value 3,728.80 (18,644 / 5)', pg_temp.n(r,'{sales,units_sold}')=3 and pg_temp.n(r,'{sales,avg_sale_value}')=3728.8, (r->'sales')::text);
  perform pg_temp.chk('t9/t10 leads new 5 / won 2 / lost 1 / 40.0 %', pg_temp.n(r,'{sales,leads,new}')=5 and pg_temp.n(r,'{sales,leads,won}')=2 and pg_temp.n(r,'{sales,leads,lost}')=1 and pg_temp.n(r,'{sales,leads,won_percent}')=40.0, (r->'sales'->'leads')::text);
  -- buyers in Oct: cA, cB, cC, cD = 4; repeat = cA (Sep 30 invoice) = 1; new 3; rate 25.0
  perform pg_temp.chk('t16 buyers 4 / repeat 1 / new 3 / 25.0 %', pg_temp.n(r,'{sales,repeat_buyers,buying_customers}')=4 and pg_temp.n(r,'{sales,repeat_buyers,repeat_buyers}')=1
    and pg_temp.n(r,'{sales,repeat_buyers,new_buyers}')=3 and pg_temp.n(r,'{sales,repeat_buyers,repeat_rate_percent}')=25.0, (r->'sales'->'repeat_buyers')::text);
  perform pg_temp.chk('t12 open tickets 3 / urgent 2 / past SLA 1', pg_temp.n(r,'{service,open_tickets,count}')=3 and pg_temp.n(r,'{service,open_tickets,urgent}')=2 and pg_temp.n(r,'{service,open_tickets,past_sla}')=1, (r->'service'->'open_tickets')::text);
  perform pg_temp.chk('t13 resolved within 24h 1 of 2 = 50.0 %', pg_temp.n(r,'{service,resolved_within_24h,resolved}')=1 and pg_temp.n(r,'{service,resolved_within_24h,completed}')=2 and pg_temp.n(r,'{service,resolved_within_24h,percent}')=50.0, (r->'service'->'resolved_within_24h')::text);
  perform pg_temp.chk('t14 rating average 4.0 over 3, below 4.5 = 2', pg_temp.n(r,'{service,rating,average}')=4.0 and pg_temp.n(r,'{service,rating,count}')=3 and pg_temp.n(r,'{service,rating,below_4_5}')=2, (r->'service'->'rating')::text);
  perform pg_temp.chk('t15 AMC active 2 / renewal window 1 / revenue 2,360', pg_temp.n(r,'{service,amc,active}')=2 and pg_temp.n(r,'{service,amc,renewal_window}')=1 and pg_temp.n(r,'{service,amc,revenue}')=2360, (r->'service'->'amc')::text);
  perform pg_temp.chk('t4 spend 14,200 (excl. purchase 10,200), 5 categories',
    pg_temp.n(r,'{money_out,spend,total}')=14200 and pg_temp.n(r,'{money_out,spend,operating_excl_purchase}')=10200 and jsonb_array_length(r #> '{money_out,spend,by_category}')=5, (r->'money_out'->'spend')::text);
  perform pg_temp.chk('t5 cash profit = 14,894.92 - 14,200 = 694.92', pg_temp.n(r,'{money_out,cash_profit,profit}')=694.92 and pg_temp.n(r,'{money_out,cash_profit,collected_net}')=14894.92, (r->'money_out'->'cash_profit')::text);
  -- margin: revenue (cost known) 9,500+1,000+450 = 10,950; cost 7,000+400+200 = 7,600; profit 3,350; 30.6 %; 1 line without cost
  perform pg_temp.chk('t6 item margin revenue 10,950 / cost 7,600 / profit 3,350 / 30.6 % ; cost_missing true with 1 line',
    pg_temp.n(r,'{money_out,item_margin,revenue}')=10950 and pg_temp.n(r,'{money_out,item_margin,cost}')=7600 and pg_temp.n(r,'{money_out,item_margin,profit}')=3350
    and pg_temp.n(r,'{money_out,item_margin,margin_percent}')=30.6 and pg_temp.n(r,'{money_out,item_margin,missing_cost_count}')=1 and (r #>> '{money_out,item_margin,cost_missing}')='true', (r->'money_out'->'item_margin')::text);
  perform pg_temp.chk('t6 purchase bills never enter item margin (cost is only invoice_items.cost)', pg_temp.n(r,'{money_out,item_margin,cost}')=7600);

  -- ===== parity with the existing report functions (same window, as the master) =====
  perform pg_temp.as_user(m);
  pnl := public.report_pnl(date '2026-10-01', date '2026-10-31');
  ss := public.report_sales_service(date '2026-10-01', date '2026-10-31');
  fun := public.get_lead_funnel(timestamptz '2026-09-30 18:30:00+00', timestamptz '2026-10-31 18:29:59.999999+00');
  opr := public.report_ops_resolution(date '2026-10-01', date '2026-10-31');
  fb := public.report_feedback(date '2026-10-01', date '2026-10-31');
  cust_tot := public.report_customer_totals(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('parity t1/t2 with report_pnl (invoiced total+net, collected total+net)',
    pg_temp.n(r,'{sales,invoiced,total}')=pg_temp.n(pnl,'{invoiced,total}') and pg_temp.n(r,'{sales,invoiced,net}')=pg_temp.n(pnl,'{invoiced,net}')
    and pg_temp.n(r,'{sales,collected,total}')=pg_temp.n(pnl,'{collected,total}') and pg_temp.n(r,'{sales,collected,net}')=pg_temp.n(pnl,'{collected,net}'));
  perform pg_temp.chk('parity t4 with report_pnl expenses_by_category',
    pg_temp.n(r,'{money_out,spend,total}') = (select sum((e->>'amount')::numeric) from jsonb_array_elements(pnl->'expenses_by_category') e));
  perform pg_temp.chk('parity t6 with report_pnl item_profit (revenue, cost, missing count)',
    pg_temp.n(r,'{money_out,item_margin,revenue}')=pg_temp.n(pnl,'{item_profit,revenue}') and pg_temp.n(r,'{money_out,item_margin,cost}')=pg_temp.n(pnl,'{item_profit,cost}')
    and pg_temp.n(r,'{money_out,item_margin,missing_cost_count}')=pg_temp.n(pnl,'{item_profit,missing_cost_count}'));
  perform pg_temp.chk('parity t7 with report_sales_service by_class (sales, service, amc, rental)',
    pg_temp.n(r,'{sales,streams,service}')=pg_temp.n(ss,'{by_class,service,total}') and pg_temp.n(r,'{sales,streams,amc}')=pg_temp.n(ss,'{by_class,amc,total}')
    and pg_temp.n(r,'{sales,streams,rental}')=pg_temp.n(ss,'{by_class,rental,total}')
    and pg_temp.n(r,'{sales,streams,product}')+pg_temp.n(r,'{sales,streams,spare_counter}')+pg_temp.n(r,'{sales,streams,gst_and_adjustments}')=pg_temp.n(ss,'{by_class,sales,total}'));
  perform pg_temp.chk('parity t9/t10 with get_lead_funnel', pg_temp.n(r,'{sales,leads,new}')=pg_temp.n(fun,'{total}') and pg_temp.n(r,'{sales,leads,won}')=pg_temp.n(fun,'{by_status,won}'));
  perform pg_temp.chk('parity t13 with report_ops_resolution', pg_temp.n(r,'{service,resolved_within_24h,percent}')=pg_temp.n(opr,'{percent}'));
  perform pg_temp.chk('parity t14 with report_feedback', pg_temp.n(r,'{service,rating,average}')=pg_temp.n(fb,'{average_rating}'));
  perform pg_temp.chk('parity t16 with report_customer_totals', pg_temp.n(r,'{sales,repeat_buyers,repeat_rate_percent}')=pg_temp.n(cust_tot,'{repeat_rate_percent}'));

  -- ===== boundary: IST midnight edges =====
  r1 := pg_temp.kpi(m, date '2026-10-01', date '2026-10-01');
  perform pg_temp.chk('boundary: window Oct 1 only holds the 00:30 IST invoice (118)', pg_temp.n(r1,'{sales,invoiced,total}')=118 and pg_temp.n(r1,'{sales,invoiced,count}')=1, (r1->'sales'->'invoiced')::text);
  r1 := pg_temp.kpi(m, date '2026-10-31', date '2026-10-31');
  perform pg_temp.chk('boundary: window Oct 31 only holds the 23:50 IST invoice (236)', pg_temp.n(r1,'{sales,invoiced,total}')=236 and pg_temp.n(r1,'{sales,invoiced,count}')=1);
  r1 := pg_temp.kpi(m, date '2026-09-30', date '2026-09-30');
  perform pg_temp.chk('boundary: window Sep 30 only holds the 23:50 IST invoice (354)', pg_temp.n(r1,'{sales,invoiced,total}')=354 and pg_temp.n(r1,'{sales,invoiced,count}')=1);
  r1 := pg_temp.kpi(m, date '2026-11-01', date '2026-11-01');
  perform pg_temp.chk('boundary: window Nov 1 only holds the 00:30 IST invoice (472)', pg_temp.n(r1,'{sales,invoiced,total}')=472 and pg_temp.n(r1,'{sales,invoiced,count}')=1);
  r1 := pg_temp.kpi(m, date '2030-01-01', date '2030-01-31');
  perform pg_temp.chk('empty window: zeros / nulls, no division errors, cost_missing false',
    pg_temp.n(r1,'{sales,invoiced,total}')=0 and pg_temp.n(r1,'{sales,avg_sale_value}')=0 and r1 #>> '{sales,leads,won_percent}' is null and r1 #>> '{money_out,item_margin,margin_percent}' is null
    and (r1 #>> '{money_out,item_margin,cost_missing}')='false' and r1 #>> '{service,resolved_within_24h,percent}' is null and r1 #>> '{service,rating,average}' is null, r1::text);
  perform pg_temp.chk('bad input: null and reversed windows raise',
    (pg_temp.kpi(m, null, date '2026-10-31')->>'error') like '%required%' and (pg_temp.kpi(m, date '2026-10-31', date '2026-10-01')->>'error') like '%must not be before%');

  -- ===== flag exclusion: add flagged-customer rows of every kind, output must be byte-identical =====
  r0 := pg_temp.kpi(m, date '2026-10-01', date '2026-10-31');
  mob := (select mobile from public.customers where id = cT);
  iT := pg_temp.mkinv(o, cT, 'product', 15254, 100000, 0, timestamptz '2026-10-15 12:00:00+05:30');          -- big, DUE, in window
  perform pg_temp.mkitem(o, iT, 'product', prodX, 5, 20000, 0, 1000, timestamptz '2026-10-15 12:00:00+05:30');
  insert into public.leads (org_id, customer_id, name, source, status, created_at) values (o, cT, '__T flagged lead', 'field', 'won', timestamptz '2026-10-15 10:00:00+05:30');
  insert into public.leads (org_id, name, mobile, source, status, created_at) values (o, '__T matched lead', mob, 'field', 'won', timestamptz '2026-10-15 10:00:00+05:30');
  tkT := pg_temp.mkticket(o, cT, iT, 'open', 'urgent', now() - interval '2 days', timestamptz '2026-10-15 09:00:00+05:30', timestamptz '2026-10-15 09:00:00+05:30');
  vT := pg_temp.mkvisit(o, tkT, tech, timestamptz '2026-10-15 11:00:00+05:30', 700);
  insert into public.ratings (org_id, visit_id, stars, created_at) values (o, vT, 1, timestamptz '2026-10-15 12:00:00+05:30');
  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values (o, cT, prodX, plan, current_date - 300, current_date + 10, 'due_soon');
  r1 := pg_temp.kpi(m, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('FLAG: invoice, lead (by customer), lead (by mobile only), urgent past-SLA ticket, visit rating 1, AMC of an is_test customer -> output byte-identical',
    r0::text = r1::text, case when r0::text = r1::text then 'identical' else 'DIFF ' || r1::text end);
  perform pg_temp.chk('FLAG: the mobile-matched lead really is flagged by the trigger',
    (select count(*) from public.leads where org_id = o and is_test) = 2);

  -- ===== two-organisation isolation: heavy org B rows must not move org A =====
  r0 := pg_temp.kpi(m, date '2026-10-01', date '2026-10-31');
  cX := pg_temp.mkcust(o2, 'B Customer');
  iX := pg_temp.mkinv(o2, cX, 'product', 1800000, 11800000, 100000, timestamptz '2026-10-10 12:00:00+05:30');
  insert into public.brands (org_id, name, category) values (o2, '__T Bbrand', 'ro') returning id into brand;
  perform pg_temp.mkitem(o2, iX, 'spare', gen_random_uuid(), 3, 100, 0, 10, timestamptz '2026-10-10 12:00:00+05:30');
  insert into public.expenses (org_id, category, amount, date) values (o2, 'salary', 7777777, date '2026-10-10'), (o2, 'purchase', 123456, date '2026-10-11');
  insert into public.leads (org_id, name, source, status, created_at) values (o2, '__T B lead', 'field', 'won', timestamptz '2026-10-10 10:00:00+05:30');
  tkX := pg_temp.mkticket(o2, cX, iX, 'open', 'very_urgent', now() - interval '5 days', timestamptz '2026-10-10 10:00:00+05:30', timestamptz '2026-10-10 10:00:00+05:30');
  r1 := pg_temp.kpi(m, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('ISOLATION: heavy rows added to org B -> org A master output byte-identical', r0::text = r1::text, case when r0::text = r1::text then 'identical' else 'DIFF' end);
  r2 := pg_temp.kpi(m2, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('ISOLATION: org B master sees only org B (invoiced 11,800,000; spend 7,901,233; 1 open ticket)',
    pg_temp.n(r2,'{sales,invoiced,total}')=11800000 and pg_temp.n(r2,'{money_out,spend,total}')=7901233 and pg_temp.n(r2,'{service,open_tickets,count}')=1 and pg_temp.n(r2,'{sales,leads,new}')=1, r2::text);

  -- ===== roles: security matrix =====
  perform pg_temp.chk('ROLE operation_admin: sales + service visible, money_out is null',
    jsonb_typeof(pg_temp.kpi(opa, date '2026-10-01', date '2026-10-31') -> 'money_out') = 'null'
    and jsonb_typeof(pg_temp.kpi(opa, date '2026-10-01', date '2026-10-31') -> 'sales') = 'object'
    and jsonb_typeof(pg_temp.kpi(opa, date '2026-10-01', date '2026-10-31') -> 'service') = 'object');
  r1 := pg_temp.kpi(sa, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('ROLE sales_admin: only sales tiles (service and money_out null)', jsonb_typeof(r1->'sales') = 'object' and jsonb_typeof(r1->'service') = 'null' and jsonb_typeof(r1->'money_out') = 'null' and r1->>'role' = 'sales_admin', left(r1::text, 100));
  perform pg_temp.chk('ROLE sales_admin: numbers equal the master''s sales group', (r1->'sales')::text = (r->'sales')::text);
  perform pg_temp.chk('ROLE technician refused', (pg_temp.kpi(tcu, date '2026-10-01', date '2026-10-31')->>'error') like 'not permitted%', pg_temp.kpi(tcu, date '2026-10-01', date '2026-10-31')::text);
  perform pg_temp.chk('ROLE customer refused', (pg_temp.kpi(cu, date '2026-10-01', date '2026-10-31')->>'error') like 'not permitted%');
  perform pg_temp.chk('ROLE inactive sales_admin refused', (pg_temp.kpi(ina, date '2026-10-01', date '2026-10-31')->>'error') like 'not permitted%');
  perform pg_temp.chk('ROLE unknown caller (no profile) refused', (pg_temp.kpi(gen_random_uuid(), date '2026-10-01', date '2026-10-31')->>'error') like 'not permitted%');
  begin
    execute 'set local role anon'; perform public.report_kpi_tiles(date '2026-10-01', date '2026-10-31'); ea := 'NO ERROR';
  exception when others then ea := sqlerrm; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('ROLE anon: permission denied', ea like 'permission denied%', ea);
  perform pg_temp.chk('ROLE other organisation''s master cannot read org A (sees org B figures only; org A invoiced 22,656 not present)', pg_temp.n(r2,'{sales,invoiced,total}') <> 22656);

  -- ===== structure: no organisation parameter, definer + search_path, ACL =====
  perform pg_temp.chk('STRUCT: signature is (p_from date, p_to date) - no organisation parameter',
    (select pg_get_function_arguments(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'report_kpi_tiles') = 'p_from date, p_to date');
  declare f record; grantees text;
  begin
    select p.prosecdef, p.provolatile, p.proconfig::text as cfg,
           coalesce((select string_agg(distinct case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end, ',' order by case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end)
                     from aclexplode(p.proacl) a), 'NULL(default PUBLIC)') as grantees
      into f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'report_kpi_tiles';
    perform pg_temp.chk('STRUCT: SECURITY DEFINER, STABLE, fixed search_path = public', f.prosecdef and f.provolatile = 's' and f.cfg like '%search_path=public%', f.cfg);
    perform pg_temp.chk('STRUCT: EXECUTE = {authenticated, postgres, service_role}; PUBLIC and anon revoked', f.grantees = 'authenticated,postgres,service_role', f.grantees);
  end;
  perform pg_temp.chk('STRUCT: outstanding-receivable partial index exists', exists (select 1 from pg_indexes where indexname = 'invoices_org_outstanding_idx'));

  -- real data untouched
  select md5(coalesce(string_agg(id::text || total::text || amount_paid::text, ',' order by id), '')) into fp2 from public.invoices
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  perform pg_temp.chk('real-organisation invoices unchanged (fingerprint)', fp1 = fp2);

  select string_agg(r2x.line, E'\n' order by r2x.n) into txt from pg_temp.res r2x;
  raise exception E'RESULTS\n%', txt;
end $t$;
