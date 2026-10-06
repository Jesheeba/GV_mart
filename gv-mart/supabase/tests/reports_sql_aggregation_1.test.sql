-- Rolled-back DB tests for migration 20261009100000 (reports SQL aggregation 1):
-- _report_invoice_base, report_sales_service, report_pnl, report_top_customers, report_customer_totals,
-- report_product_sales. Run with the migration applied (or concatenated in front of this file - it is
-- idempotent). Everything runs in throwaway "__TEST_" organisations and ends in a RAISE, so nothing is kept.
-- Hand-written expected constants - see the arithmetic comments next to each fixture.
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

-- fixtures ---------------------------------------------------------------
create function pg_temp.mkorg(p_tag text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.organizations (name) values ('__TEST_reports_' || p_tag || '_' || gen_random_uuid()) returning id into v;
  insert into public.settings (org_id) values (v) on conflict do nothing;
  return v;
end $f$;
create function pg_temp.mkcust(p_org uuid, p_name text, p_created timestamptz default now(), p_id uuid default gen_random_uuid()) returns uuid language plpgsql as $f$
begin
  insert into public.customers (id, org_id, name, mobile, created_at) values (p_id, p_org, p_name, lpad(abs(hashtext(p_id::text)::bigint)::text, 10, '0'), p_created);
  return p_id;
end $f$;
create function pg_temp.mkinv(p_org uuid, p_cust uuid, p_type text, p_subtotal numeric, p_discount numeric, p_gst numeric, p_total numeric, p_paid numeric, p_at timestamptz) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at, updated_at)
  values (p_org, p_cust, p_type::public.invoice_type, p_subtotal, p_discount, p_gst, p_total, public._derive_payment_status(p_paid, p_total), p_paid, p_at, p_at)
  returning id into v;
  return v;
end $f$;
create function pg_temp.mkitem(p_org uuid, p_inv uuid, p_type text, p_item uuid, p_qty int, p_price numeric, p_discount numeric, p_cost numeric, p_at timestamptz) returns void language plpgsql as $f$
begin
  insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost, created_at, updated_at)
  values (p_org, p_inv, p_type::public.item_type, p_item, p_qty, p_price, p_discount, p_cost, p_at, p_at);
end $f$;
create function pg_temp.mktech(p_org uuid) returns uuid language plpgsql as $f$
declare u uuid := pg_temp.mkuser('technician', p_org); t uuid;
begin
  insert into public.technicians (org_id, profile_id) values (p_org, u) returning id into t;
  return t;
end $f$;
create function pg_temp.mkticket(p_org uuid, p_cust uuid, p_type text, p_inv uuid) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.service_tickets (org_id, customer_id, type, invoice_id) values (p_org, p_cust, p_type::public.ticket_type, p_inv) returning id into v;
  return v;
end $f$;
create function pg_temp.mkvisit(p_org uuid, p_ticket uuid, p_tech uuid, p_start timestamptz, p_charge numeric) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, service_charge, created_at, updated_at)
  values (p_org, p_ticket, p_tech, p_start, p_charge, p_start, p_start) returning id into v;
  return v;
end $f$;
create function pg_temp.n(r jsonb, p text[]) returns numeric language sql as $f$ select (r #>> p)::numeric $f$;

do $t$
declare
  txt text;
  o uuid; m uuid; sa uuid; techuser uuid; custuser uuid; t1 uuid; t2 uuid;
  o2 uuid; m2 uuid;
  cA uuid; cB uuid; cC uuid; cD uuid; cE uuid; cF uuid;
  brand uuid; model uuid; prodX uuid; prodY uuid; spareS uuid; gift uuid; gift0 uuid;
  i1 uuid; i2 uuid; i3 uuid; i4 uuid; i5 uuid; i6 uuid; i7 uuid;
  tk6 uuid; tk7 uuid; tk8 uuid; tkN uuid;
  r jsonb; r2 jsonb; r3 jsonb;
  oct text := '2026-10-01'; octe text := '2026-10-31';
begin
  o := pg_temp.mkorg('main');
  if (select name from organizations where id = o) not like '\_\_TEST\_%' then raise exception 'refusing to run outside a __TEST_ org'; end if;
  insert into public.settings (org_id) values (o) on conflict do nothing;
  m := pg_temp.mkuser('master', o);
  sa := pg_temp.mkuser('sales_admin', o);
  techuser := pg_temp.mkuser('technician', o);
  custuser := pg_temp.mkuser('customer', o);
  t1 := pg_temp.mktech(o);
  t2 := pg_temp.mktech(o);
  o2 := pg_temp.mkorg('other');
  m2 := pg_temp.mkuser('master', o2);

  cA := pg_temp.mkcust(o, 'Alpha'); cB := pg_temp.mkcust(o, 'Bravo'); cC := pg_temp.mkcust(o, 'Charlie');
  cD := pg_temp.mkcust(o, 'Delta'); cE := pg_temp.mkcust(o, 'Echo'); cF := pg_temp.mkcust(o, 'Foxtrot');

  insert into public.brands (org_id, name, category) values (o, '__T brand', 'ro') returning id into brand;
  insert into public.models (org_id, brand_id, name) values (o, brand, '__T model') returning id into model;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'Product X', 'ro', 5250) returning id into prodX;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'Product Y', 'ro', 5000) returning id into prodY;
  insert into public.spares (org_id, name, price) values (o, 'Spare S', 250) returning id into spareS;
  insert into public.gifts (org_id, name, threshold_amount, cost_price) values (o, '__T gift', 1, 150) returning id into gift;
  insert into public.gifts (org_id, name, threshold_amount) values (o, '__T gift no cost', 1) returning id into gift0;

  -- ===== Oct 2026 hand-written dataset (every created_at is an explicit IST instant) =====
  -- 1 product, discount: subtotal 10,500 - 1,000 = 9,500; GST 18% = 1,710; total 11,210, paid in full. item qty 2 @5,250 disc 1,000 cost 3,500/unit
  i1 := pg_temp.mkinv(o, cA, 'product', 10500, 1000, 1710, 11210, 11210, timestamptz '2026-10-05 12:00:00+05:30');
  perform pg_temp.mkitem(o, i1, 'product', prodX, 2, 5250, 1000, 3500, timestamptz '2026-10-05 12:00:00+05:30');
  -- 2 product, partially paid: total 5,900 (5,000 + 900 GST), paid 2,000. item qty 1 @5,000 cost 3,000
  i2 := pg_temp.mkinv(o, cB, 'product', 5000, 0, 900, 5900, 2000, timestamptz '2026-10-06 12:00:00+05:30');
  perform pg_temp.mkitem(o, i2, 'product', prodY, 1, 5000, 0, 3000, timestamptz '2026-10-06 12:00:00+05:30');
  -- 3 AMC 2,360 (2,000 + 360) paid; 4 rental 590 (500 + 90) paid
  i3 := pg_temp.mkinv(o, cA, 'amc', 2000, 0, 360, 2360, 2360, timestamptz '2026-10-07 12:00:00+05:30');
  i4 := pg_temp.mkinv(o, cB, 'rent', 500, 0, 90, 590, 590, timestamptz '2026-10-08 12:00:00+05:30');
  -- 5 plain spare counter sale 1,180 (1,000 + 180) paid. item qty 4 @250 cost 100
  i5 := pg_temp.mkinv(o, cC, 'spare', 1000, 0, 180, 1180, 1180, timestamptz '2026-10-09 12:00:00+05:30');
  perform pg_temp.mkitem(o, i5, 'spare', spareS, 4, 250, 0, 100, timestamptz '2026-10-09 12:00:00+05:30');
  -- 6 service invoice: charge 500 + spare 2 x 250 = 1,000; 10% discount 100; GST 18% of 900 = 162; total 1,062; paid in full.
  --   linked to a ticket that has a visit (charge 500). spare line qty 2 @250 disc 50 cost 100
  i6 := pg_temp.mkinv(o, cD, 'spare', 1000, 100, 162, 1062, 1062, timestamptz '2026-10-10 12:00:00+05:30');
  perform pg_temp.mkitem(o, i6, 'spare', spareS, 2, 250, 50, 100, timestamptz '2026-10-10 12:00:00+05:30');
  tk6 := pg_temp.mkticket(o, cD, 'paid', i6);
  perform pg_temp.mkvisit(o, tk6, t1, timestamptz '2026-10-10 11:00:00+05:30', 500);
  -- 7 zero-total warranty service invoice (+ visit, charge 0)
  i7 := pg_temp.mkinv(o, cE, 'spare', 0, 0, 0, 0, 0, timestamptz '2026-10-11 12:00:00+05:30');
  tk7 := pg_temp.mkticket(o, cE, 'warranty', i7);
  perform pg_temp.mkvisit(o, tk7, t2, timestamptz '2026-10-11 11:00:00+05:30', 0);
  -- 8 a service visit with NO invoice (charge 300): contributes to visits / technician table, never to collected
  tk8 := pg_temp.mkticket(o, cF, 'paid', null);
  perform pg_temp.mkvisit(o, tk8, t1, timestamptz '2026-10-12 11:00:00+05:30', 300);
  -- visits just outside the window must not count: 23:50 IST Sep 30 and 00:30 IST Nov 1
  perform pg_temp.mkvisit(o, tk8, t1, timestamptz '2026-09-30 23:50:00+05:30', 999);
  perform pg_temp.mkvisit(o, tk8, t1, timestamptz '2026-11-01 00:30:00+05:30', 111);
  -- boundary invoices (product, GST 18%): 00:30 IST Oct 1 = 118 (Oct); 23:50 IST Oct 31 = 236 (Oct); 23:50 IST Sep 30 = 354 (Sep); 00:30 IST Nov 1 = 472 (Nov)
  perform pg_temp.mkinv(o, cA, 'product', 100, 0, 18, 118, 118, timestamptz '2026-10-01 00:30:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 200, 0, 36, 236, 236, timestamptz '2026-10-31 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 300, 0, 54, 354, 354, timestamptz '2026-09-30 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 400, 0, 72, 472, 472, timestamptz '2026-11-01 00:30:00+05:30');
  -- December and year-end: Dec 15 = 590; 23:50 IST Dec 31 = 708 (2026); 00:10 IST Jan 1 2027 = 826 (2027)
  perform pg_temp.mkinv(o, cA, 'product', 500, 0, 90, 590, 590, timestamptz '2026-12-15 12:00:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 600, 0, 108, 708, 708, timestamptz '2026-12-31 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 700, 0, 126, 826, 826, timestamptz '2027-01-01 00:10:00+05:30');
  -- calls: 2 in Oct, one 23:50 IST Sep 30 and one 00:30 IST Nov 1 (outside)
  insert into public.call_logs (org_id, technician_id, called_at) values
    (o, t1, timestamptz '2026-10-02 10:00:00+05:30'), (o, t2, timestamptz '2026-10-20 10:00:00+05:30'),
    (o, t1, timestamptz '2026-09-30 23:50:00+05:30'), (o, t1, timestamptz '2026-11-01 00:30:00+05:30');
  -- expenses: salary 20,000 (Oct 31) + 5,000 (Oct 15), rent 10,000 (Oct 1); outside: petrol 700 Sep 30, petrol 800 Nov 1
  insert into public.expenses (org_id, category, amount, date) values
    (o, 'salary', 20000, date '2026-10-31'), (o, 'salary', 5000, date '2026-10-15'), (o, 'rent', 10000, date '2026-10-01'),
    (o, 'petrol', 700, date '2026-09-30'), (o, 'petrol', 800, date '2026-11-01');
  -- gift logs in Oct: one costed 150 and one whose gift has no cost price (counts as a missing cost); the insert trigger snapshots the cost
  insert into public.gift_logs (org_id, invoice_id, gift_id, created_at) values
    (o, i1, gift, timestamptz '2026-10-05 12:00:00+05:30'), (o, i1, gift0, timestamptz '2026-10-05 12:00:00+05:30');

  -- ===== invoice_base_classification (helper, as the owner: it is granted to nobody) =====
  -- extra org for the classification edge cases so the Oct numbers above stay untouched
  declare
    oc uuid := pg_temp.mkorg('classify'); cc uuid; ti uuid; tv uuid; tj uuid; tt uuid;
    a_inst uuid; b_noVisit uuid; c_two uuid; d_plain uuid; tat timestamptz := timestamptz '2026-10-15 12:00:00+05:30';
    rows_n int; cls text;
  begin
    cc := pg_temp.mkcust(oc, 'Cls');
    insert into public.settings (org_id) values (oc) on conflict do nothing;
    tt := pg_temp.mktech(oc);
    -- a: spare invoice linked from an INSTALLATION ticket that has a visit -> by the rule it is "service" (flagged ambiguous in the report)
    a_inst := pg_temp.mkinv(oc, cc, 'spare', 1500, 0, 270, 1770, 1770, tat);
    ti := pg_temp.mkticket(oc, cc, 'installation', a_inst);
    perform pg_temp.mkvisit(oc, ti, tt, tat, 0);
    -- b: spare invoice linked from a ticket with NO visit -> sales
    b_noVisit := pg_temp.mkinv(oc, cc, 'spare', 100, 0, 18, 118, 118, tat);
    perform pg_temp.mkticket(oc, cc, 'paid', b_noVisit);
    -- c: one invoice, two tickets, three visits -> still exactly one row, class service
    c_two := pg_temp.mkinv(oc, cc, 'spare', 200, 0, 36, 236, 236, tat);
    tv := pg_temp.mkticket(oc, cc, 'paid', c_two); tj := pg_temp.mkticket(oc, cc, 'paid', c_two);
    perform pg_temp.mkvisit(oc, tv, tt, tat, 100); perform pg_temp.mkvisit(oc, tv, tt, tat, 50); perform pg_temp.mkvisit(oc, tj, tt, tat, 50);
    -- d: spare invoice with no ticket at all -> sales
    d_plain := pg_temp.mkinv(oc, cc, 'spare', 300, 0, 54, 354, 354, tat);
    perform pg_temp.mkinv(oc, cc, 'product', 1, 0, 0, 1, 1, tat);
    perform pg_temp.mkinv(oc, cc, 'amc', 1, 0, 0, 1, 1, tat);
    perform pg_temp.mkinv(oc, cc, 'rent', 1, 0, 0, 1, 1, tat);

    select count(*) into rows_n from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30');
    perform pg_temp.chk('invoice_base_classification: 7 invoices -> 7 rows, none duplicated', rows_n = 7, rows_n::text);
    select class into cls from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_id = a_inst;
    perform pg_temp.chk('invoice_base_classification: spare via installation ticket WITH a visit = service (ambiguous, flagged)', cls = 'service', cls);
    select class into cls from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_id = b_noVisit;
    perform pg_temp.chk('invoice_base_classification: spare via ticket with NO visit = sales', cls = 'sales', cls);
    select class into cls from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_id = c_two;
    perform pg_temp.chk('invoice_base_classification: two tickets / three visits on one invoice = service, counted once', cls = 'service', cls);
    select class into cls from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_id = d_plain;
    perform pg_temp.chk('invoice_base_classification: spare with no ticket = sales', cls = 'sales', cls);
    perform pg_temp.chk('invoice_base_classification: product/amc/rent map to sales/amc/rental',
      (select string_agg(class, ',' order by class) from public._report_invoice_base(oc, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_type in ('product','amc','rent')) = 'amc,rental,sales');
    perform pg_temp.chk('invoice_base_classification: zero-total warranty service invoice (main org) = service',
      (select class from public._report_invoice_base(o, timestamptz '2026-10-01 00:00:00+05:30', timestamptz '2026-11-01 00:00:00+05:30') where invoice_id = i7) = 'service');
  end;

  -- ===== report_sales_service, Oct 2026, as the master =====
  perform pg_temp.as_user(m);
  r := public.report_sales_service(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  -- sales: i1 11,210 + i2 5,900 + i5 1,180 + 118 + 236 = 18,644 ; gst 1,710+900+180+18+36 = 2,844 ; collected 11,210+2,000+1,180+118+236 = 14,744 ; qty 2+1+4 = 7 ; count 5
  perform pg_temp.chk('sales_service Oct: sales class', pg_temp.n(r,'{by_class,sales,count}')=5 and pg_temp.n(r,'{by_class,sales,total}')=18644 and pg_temp.n(r,'{by_class,sales,gst}')=2844
    and pg_temp.n(r,'{by_class,sales,net}')=15800 and pg_temp.n(r,'{by_class,sales,collected}')=14744 and pg_temp.n(r,'{by_class,sales,qty}')=7, (r->'by_class'->'sales')::text);
  -- service: 1,062 + 0 ; count 2 ; gst 162 ; collected 1,062 ; qty = count
  perform pg_temp.chk('sales_service Oct: service class = full invoice totals, count 2 invoices', pg_temp.n(r,'{by_class,service,count}')=2 and pg_temp.n(r,'{by_class,service,total}')=1062
    and pg_temp.n(r,'{by_class,service,gst}')=162 and pg_temp.n(r,'{by_class,service,net}')=900 and pg_temp.n(r,'{by_class,service,collected}')=1062 and pg_temp.n(r,'{by_class,service,qty}')=2, (r->'by_class'->'service')::text);
  perform pg_temp.chk('sales_service Oct: amc 2,360 / rental 590', pg_temp.n(r,'{by_class,amc,total}')=2360 and pg_temp.n(r,'{by_class,amc,count}')=1 and pg_temp.n(r,'{by_class,amc,gst}')=360 and pg_temp.n(r,'{by_class,amc,collected}')=2360
    and pg_temp.n(r,'{by_class,rental,total}')=590 and pg_temp.n(r,'{by_class,rental,count}')=1 and pg_temp.n(r,'{by_class,rental,gst}')=90 and pg_temp.n(r,'{by_class,rental,collected}')=590);
  -- totals: count 9 ; total 18,644+1,062+2,360+590 = 22,656 ; gst 2,844+162+360+90 = 3,456 ; net 19,200 ; collected 14,744+1,062+2,360+590 = 18,756
  perform pg_temp.chk('sales_service Oct: totals', pg_temp.n(r,'{totals,count}')=9 and pg_temp.n(r,'{totals,total}')=22656 and pg_temp.n(r,'{totals,gst}')=3456
    and pg_temp.n(r,'{totals,net}')=19200 and pg_temp.n(r,'{totals,collected}')=18756, (r->'totals')::text);
  -- by invoice type: product 4 / 17,464 ; spare 3 / 2,242 ; amc 1 / 2,360 ; rent 1 / 590
  perform pg_temp.chk('sales_service Oct: by_invoice_type', (r->'by_invoice_type') = jsonb_build_array(
      jsonb_build_object('type','product','count',4,'total',17464), jsonb_build_object('type','spare','count',3,'total',2242),
      jsonb_build_object('type','amc','count',1,'total',2360), jsonb_build_object('type','rent','count',1,'total',590)), (r->'by_invoice_type')::text);
  -- visits in window: i6's, i7's, the no-invoice one = 3 ; calls 2 ; technicians: t1 2 visits 800, t2 1 visit 0 ; avg 1,062 / 2 = 531
  perform pg_temp.chk('sales_service Oct: visits / calls / avg per service call', pg_temp.n(r,'{service_visits}')=3 and pg_temp.n(r,'{calls}')=2 and pg_temp.n(r,'{avg_value_per_service_call}')=531, r::text);
  perform pg_temp.chk('sales_service Oct: technician table is service_charge per visit', (r->'technicians'->0->>'technician_id') = t1::text and pg_temp.n(r,'{technicians,0,count}')=2 and pg_temp.n(r,'{technicians,0,revenue}')=800
    and (r->'technicians'->1->>'technician_id') = t2::text and pg_temp.n(r,'{technicians,1,count}')=1 and pg_temp.n(r,'{technicians,1,revenue}')=0, (r->'technicians')::text);

  -- ===== service_no_invoice_zero_collected (own org: only a visit, no invoice) =====
  declare osv uuid := pg_temp.mkorg('novoice'); msv uuid; cv uuid; tsv uuid; tv2 uuid; rr jsonb; rp jsonb;
  begin
    msv := pg_temp.mkuser('master', osv); cv := pg_temp.mkcust(osv, 'V'); tsv := pg_temp.mktech(osv);
    perform pg_temp.mkvisit(osv, pg_temp.mkticket(osv, cv, 'paid', null), tsv, timestamptz '2026-10-12 11:00:00+05:30', 300);
    perform pg_temp.as_user(msv);
    rr := public.report_sales_service(date '2026-10-01', date '2026-10-31');
    rp := public.report_pnl(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('service_no_invoice_zero_collected: visit with no invoice -> service total 0, collected 0, but visit 1 / technician revenue 300',
      pg_temp.n(rr,'{by_class,service,total}')=0 and pg_temp.n(rr,'{by_class,service,count}')=0 and pg_temp.n(rr,'{by_class,service,collected}')=0 and pg_temp.n(rr,'{totals,collected}')=0
      and pg_temp.n(rr,'{service_visits}')=1 and pg_temp.n(rr,'{technicians,0,revenue}')=300 and pg_temp.n(rr,'{avg_value_per_service_call}')=0 and pg_temp.n(rp,'{collected,total}')=0, rr::text);
  end;

  -- ===== report_pnl, Oct 2026 =====
  perform pg_temp.as_user(m);
  r2 := public.report_pnl(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('partial_payment_and_discount_gst: invoiced = 22,656 incl 3,456 GST (net 19,200); collected 18,756',
    pg_temp.n(r2,'{invoiced,total}')=22656 and pg_temp.n(r2,'{invoiced,gst}')=3456 and pg_temp.n(r2,'{invoiced,net}')=19200 and pg_temp.n(r2,'{collected,total}')=18756, (r2->'invoiced')::text || (r2->'collected')::text);
  -- GST of payments prorated: 1,710 + 2,000*900/5,900 (=305.0847) + 180 + 18 + 36 + 162 + 360 + 90 = 2,861.0847 -> 2,861.08 ; net 18,756 - 2,861.08 = 15,894.92
  perform pg_temp.chk('partial_payment_and_discount_gst: collected GST prorated by each invoice''s own gst/total', pg_temp.n(r2,'{collected,gst}')=2861.08 and pg_temp.n(r2,'{collected,net}')=15894.92, (r2->'collected')::text);
  perform pg_temp.chk('partial_payment_and_discount_gst: P1 discount arithmetic (10,500 - 1,000 + 18% = 11,210)', (select total from invoices where id = i1) = 11210 and 10500 - 1000 + (10500 - 1000) * 0.18 = 11210);
  perform pg_temp.chk('pnl Oct: expenses by category (master): salary 25,000, rent 10,000 (Sep 30 / Nov 1 petrol excluded)', (r2->'expenses_by_category') = jsonb_build_array(
      jsonb_build_object('category','salary','amount',25000), jsonb_build_object('category','rent','amount',10000)), (r2->'expenses_by_category')::text);
  -- items with a cost: revenue 9,500 + 5,000 + 1,000 + 450 = 15,950 ; cost 7,000 + 3,000 + 400 + 200 = 10,600 ; gifts 150 ; one gift with no cost -> missing 1
  perform pg_temp.chk('pnl Oct: item profit', pg_temp.n(r2,'{item_profit,revenue}')=15950 and pg_temp.n(r2,'{item_profit,cost}')=10600 and pg_temp.n(r2,'{item_profit,gifts_cost}')=150 and pg_temp.n(r2,'{item_profit,missing_cost_count}')=1, (r2->'item_profit')::text);

  -- ===== sales_service_equals_pnl across windows: both read the same invoice set =====
  declare w record; ok boolean := true; info text := '';
  begin
    for w in select * from (values (date '2026-10-01', date '2026-10-31'), (date '2026-09-01', date '2026-09-30'), (date '2026-11-01', date '2026-11-30'),
        (date '2026-12-01', date '2026-12-31'), (date '2026-01-01', date '2026-12-31'), (date '2027-01-01', date '2027-12-31'), (date '2026-10-12', date '2026-10-12')) v(f, t)
    loop
      perform pg_temp.as_user(m);
      r := public.report_sales_service(w.f, w.t);
      r2 := public.report_pnl(w.f, w.t);
      perform pg_temp.as_pg();
      if not (pg_temp.n(r,'{totals,total}') = pg_temp.n(r2,'{invoiced,total}') and pg_temp.n(r,'{totals,gst}') = pg_temp.n(r2,'{invoiced,gst}')
              and pg_temp.n(r,'{totals,collected}') = pg_temp.n(r2,'{collected,total}')
              and pg_temp.n(r,'{totals,total}') = pg_temp.n(r,'{by_class,sales,total}') + pg_temp.n(r,'{by_class,service,total}') + pg_temp.n(r,'{by_class,amc,total}') + pg_temp.n(r,'{by_class,rental,total}')
              and pg_temp.n(r,'{totals,count}') = pg_temp.n(r,'{by_class,sales,count}') + pg_temp.n(r,'{by_class,service,count}') + pg_temp.n(r,'{by_class,amc,count}') + pg_temp.n(r,'{by_class,rental,count}')) then
        ok := false; info := info || w.f || '..' || w.t || ' ';
      end if;
    end loop;
    perform pg_temp.chk('sales_service_equals_pnl: totals / GST / collected agree in 7 windows and the classes sum to the total', ok, info);
  end;

  -- ===== ist_boundaries =====
  perform pg_temp.as_user(m);
  r := public.report_sales_service(date '2026-10-01', date '2026-10-31');
  r2 := public.report_sales_service(date '2026-09-01', date '2026-09-30');
  r3 := public.report_sales_service(date '2026-11-01', date '2026-11-30');
  perform pg_temp.as_pg();
  perform pg_temp.chk('ist_boundaries: 00:30 IST Oct 1 (= Sep 30 UTC) and 23:50 IST Oct 31 are in October (118 and 236 inside the 18,644 sales total)', pg_temp.n(r,'{by_class,sales,total}')=18644 and pg_temp.n(r,'{totals,count}')=9);
  perform pg_temp.chk('ist_boundaries: September holds only the 23:50 IST Sep 30 invoice (354)', pg_temp.n(r2,'{totals,count}')=1 and pg_temp.n(r2,'{totals,total}')=354 and pg_temp.n(r2,'{calls}')=1 and pg_temp.n(r2,'{service_visits}')=1, r2::text);
  perform pg_temp.chk('ist_boundaries: November holds only the 00:30 IST Nov 1 invoice (472)', pg_temp.n(r3,'{totals,count}')=1 and pg_temp.n(r3,'{totals,total}')=472 and pg_temp.n(r3,'{calls}')=1 and pg_temp.n(r3,'{service_visits}')=1, r3::text);
  perform pg_temp.as_user(m);
  r := public.report_sales_service(date '2026-12-01', date '2026-12-31');
  r2 := public.report_sales_service(date '2026-01-01', date '2026-12-31');
  r3 := public.report_sales_service(date '2027-01-01', date '2027-12-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('ist_boundaries: December = 590 + 708 (23:50 IST Dec 31), not the 00:10 IST Jan 1 invoice', pg_temp.n(r,'{totals,total}')=1298 and pg_temp.n(r,'{totals,count}')=2, r::text);
  -- 2026: Sep 354 + Oct 22,656 + Nov 472 + Dec 1,298 = 24,780 ; 2027: 826
  perform pg_temp.chk('ist_boundaries: year 2026 = 24,780 (nothing from 2027); 2027 = 826', pg_temp.n(r2,'{totals,total}')=24780 and pg_temp.n(r2,'{totals,count}')=13 and pg_temp.n(r3,'{totals,total}')=826 and pg_temp.n(r3,'{totals,count}')=1, r2::text || ' / ' || r3::text);
  perform pg_temp.chk('ist_boundaries: expenses use the plain date (Oct 1 and Oct 31 inside; Sep 30 / Nov 1 outside) - checked in pnl above', true);
  perform pg_temp.as_user(m);
  r := public.report_sales_service(date '2026-10-31', date '2026-10-01');
  perform pg_temp.as_pg();
  perform pg_temp.chk('ist_boundaries: from > to gives an empty window, not an error', pg_temp.n(r,'{totals,count}')=0 and pg_temp.n(r,'{totals,total}')=0, r::text);

  -- ===== non_master_gets_zero_expenses + role gates =====
  perform pg_temp.as_user(sa);
  r := public.report_pnl(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('non_master_gets_zero_expenses: sales_admin sees invoices but expenses_by_category = []', (r->'expenses_by_category') = '[]'::jsonb and pg_temp.n(r,'{invoiced,total}')=22656, (r->'expenses_by_category')::text);
  declare e1 text; e2 text;
  begin
    begin perform pg_temp.as_user(techuser); perform public.report_pnl(date '2026-10-01', date '2026-10-31'); e1 := 'NO ERROR';
    exception when others then e1 := sqlerrm; end;
    perform pg_temp.as_pg();
    begin perform pg_temp.as_user(custuser); perform public.report_sales_service(date '2026-10-01', date '2026-10-31'); e2 := 'NO ERROR';
    exception when others then e2 := sqlerrm; end;
    perform pg_temp.as_pg();
    perform pg_temp.chk('role gate: technician and customer are rejected by every report function',
      e1 like 'not permitted%' and e2 like 'not permitted%', e1 || ' / ' || e2);
    declare fn text; bad text := '';
    begin
      foreach fn in array array[
        'public.report_sales_service(date ''2026-10-01'', date ''2026-10-31'')', 'public.report_pnl(date ''2026-10-01'', date ''2026-10-31'')',
        'public.report_top_customers(date ''2026-10-01'', date ''2026-10-31'', 10)', 'public.report_customer_totals(date ''2026-10-01'', date ''2026-10-31'')',
        'public.report_product_sales(date ''2026-10-01'', date ''2026-10-31'')'] loop
        foreach e1 in array array[techuser::text, custuser::text] loop
          begin perform pg_temp.as_user(e1::uuid); execute 'select ' || fn; bad := bad || fn || ' ';
          exception when others then if sqlerrm not like 'not permitted%' then bad := bad || '[' || sqlerrm || '] '; end if; end;
          perform pg_temp.as_pg();
        end loop;
      end loop;
      perform pg_temp.chk('role gate: all 5 functions x (technician, customer) raise "not permitted"', bad = '', bad);
    end;
  end;
  -- another organisation's master sees zeros, not this org's money
  perform pg_temp.as_user(m2);
  r := public.report_sales_service(date '2026-10-01', date '2026-10-31');
  r2 := public.report_pnl(date '2026-10-01', date '2026-10-31');
  r3 := public.report_top_customers(date '2026-10-01', date '2026-10-31', 50);
  perform pg_temp.as_pg();
  perform pg_temp.chk('cross-org: a master of another organisation sees zeros / empty', pg_temp.n(r,'{totals,count}')=0 and pg_temp.n(r2,'{invoiced,total}')=0 and (r2->'expenses_by_category') = '[]'::jsonb and r3 = '[]'::jsonb);

  -- ===== product_sales_missing_cost_null + report_product_sales Oct =====
  perform pg_temp.as_user(m);
  r := public.report_product_sales(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  -- X: qty 2 rev 9,500 cost 7,000 profit 2,500 margin 26.3 share 59.6 avg 4,750 ; Y: 1 / 5,000 / 3,000 / 2,000 / 40.0 / 31.3 / 5,000 ;
  -- S (two invoices): qty 6 rev 1,450 cost 600 profit 850 margin 58.6 share 9.1 avg 241.67 ; total revenue 15,950
  perform pg_temp.chk('product_sales Oct: 3 rows, revenue-ordered X, Y, S', jsonb_array_length(r) = 3 and r->0->>'name' = 'Product X' and r->1->>'name' = 'Product Y' and r->2->>'name' = 'Spare S', (select string_agg(x->>'name', ',') from jsonb_array_elements(r) x));
  perform pg_temp.chk('product_sales Oct: X', pg_temp.n(r,'{0,qty}')=2 and pg_temp.n(r,'{0,revenue}')=9500 and pg_temp.n(r,'{0,cost}')=7000 and pg_temp.n(r,'{0,profit}')=2500 and pg_temp.n(r,'{0,margin_percent}')=26.3
    and pg_temp.n(r,'{0,share_percent}')=59.6 and pg_temp.n(r,'{0,avg_price}')=4750 and pg_temp.n(r,'{0,invoice_count}')=1 and r->0->>'item_type'='product' and r->0->>'category' = 'ro', (r->0)::text);
  perform pg_temp.chk('product_sales Oct: spare S spans a counter sale and the service invoice', pg_temp.n(r,'{2,qty}')=6 and pg_temp.n(r,'{2,revenue}')=1450 and pg_temp.n(r,'{2,cost}')=600 and pg_temp.n(r,'{2,profit}')=850
    and pg_temp.n(r,'{2,margin_percent}')=58.6 and pg_temp.n(r,'{2,share_percent}')=9.1 and pg_temp.n(r,'{2,avg_price}')=241.67 and pg_temp.n(r,'{2,invoice_count}')=2, (r->2)::text);
  declare omc uuid := pg_temp.mkorg('misscost'); mmc uuid; cmc uuid; imc uuid; pa uuid; pb uuid; br uuid; md uuid; tat timestamptz := timestamptz '2026-10-15 12:00:00+05:30';
  begin
    mmc := pg_temp.mkuser('master', omc); cmc := pg_temp.mkcust(omc, 'MC');
    insert into public.brands (org_id, name, category) values (omc, 'b', 'ro') returning id into br;
    insert into public.models (org_id, brand_id, name) values (omc, br, 'm') returning id into md;
    insert into public.products (org_id, brand_id, model_id, name, category, price) values (omc, br, md, 'WithCost', 'ro', 100) returning id into pa;
    insert into public.products (org_id, brand_id, model_id, name, category, price) values (omc, br, md, 'MissingCost', 'ro', 100) returning id into pb;
    imc := pg_temp.mkinv(omc, cmc, 'product', 300, 0, 54, 354, 354, tat);
    perform pg_temp.mkitem(omc, imc, 'product', pa, 1, 100, 0, 60, tat);
    perform pg_temp.mkitem(omc, imc, 'product', pb, 1, 100, 0, null, tat);
    perform pg_temp.mkitem(omc, imc, 'product', pb, 1, 100, 0, 70, tat);   -- one costed line of the same product does not rescue it
    perform pg_temp.mkitem(omc, imc, 'gift', gen_random_uuid(), 1, 0, 0, null, tat);   -- gift lines are not product sales
    perform pg_temp.as_user(mmc);
    r := public.report_product_sales(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('product_sales_missing_cost_null: any uncosted line -> cost/profit/margin NULL (not 0); costed product keeps real numbers; gift excluded',
      jsonb_array_length(r) = 2
      and (select x->>'cost' is null and x->>'profit' is null and x->>'margin_percent' is null and (x->>'qty')::int = 2 and (x->>'revenue')::numeric = 200 from jsonb_array_elements(r) x where x->>'name' = 'MissingCost')
      and (select (x->>'cost')::numeric = 60 and (x->>'profit')::numeric = 40 and (x->>'margin_percent')::numeric = 40.0 from jsonb_array_elements(r) x where x->>'name' = 'WithCost'), r::text);
  end;

  -- ===== top_customers_ranking_and_ties =====
  declare otc uuid := pg_temp.mkorg('topcust'); mtc uuid; c1 uuid; c2 uuid; c3 uuid; c4 uuid; tat timestamptz := timestamptz '2026-10-15 12:00:00+05:30'; k int;
  begin
    mtc := pg_temp.mkuser('master', otc);
    -- c2 and c3 tie on 1,000; the lower customer id (aaaa..) must rank first, repeatably
    c3 := pg_temp.mkcust(otc, 'Tie B', now(), 'bbbbbbbb-0000-0000-0000-000000000001');
    c2 := pg_temp.mkcust(otc, 'Tie A', now(), 'aaaaaaaa-0000-0000-0000-000000000001');
    c1 := pg_temp.mkcust(otc, 'Big', now());
    c4 := pg_temp.mkcust(otc, 'Small', now());
    insert into public.addresses (org_id, customer_id, area, pincode, is_primary, created_at) values
      (otc, c1, 'Secondary Area', '600002', false, now() - interval '1 day'), (otc, c1, 'Primary Area', '600001', true, now());
    perform pg_temp.mkinv(otc, c1, 'product', 3000, 0, 0, 3000, 2500, tat);
    perform pg_temp.mkinv(otc, c1, 'amc', 2000, 0, 0, 2000, 2000, tat + interval '1 day');   -- c1 = 5,000 invoiced over 2 invoices
    perform pg_temp.mkinv(otc, c2, 'product', 1000, 0, 0, 1000, 1000, tat);
    perform pg_temp.mkinv(otc, c3, 'product', 1000, 0, 0, 1000, 400, tat);
    perform pg_temp.mkinv(otc, c4, 'product', 10, 0, 0, 10, 10, tat);
    perform pg_temp.as_user(mtc);
    r := public.report_top_customers(date '2026-10-01', date '2026-10-31', 50);
    r2 := public.report_top_customers(date '2026-10-01', date '2026-10-31', 2);
    r3 := public.report_top_customers(date '2026-10-01', date '2026-10-31', 0);
    perform pg_temp.as_pg();
    perform pg_temp.chk('top_customers_ranking_and_ties: order Big, Tie A, Tie B, Small; ranks 1..4', (select string_agg(x->>'rank' || ':' || (x->>'name'), ',' order by (x->>'rank')::int) from jsonb_array_elements(r) x) = '1:Big,2:Tie A,3:Tie B,4:Small',
      (select string_agg(x->>'rank' || ':' || (x->>'name'), ',') from jsonb_array_elements(r) x));
    perform pg_temp.chk('top_customers: Big = 5,000 invoiced, 4,500 collected, 2 invoices, primary-address area + pincode, first/last purchase',
      pg_temp.n(r,'{0,invoiced_total}')=5000 and pg_temp.n(r,'{0,collected_total}')=4500 and pg_temp.n(r,'{0,invoice_count}')=2 and r->0->>'area' = 'Primary Area' and r->0->>'pincode' = '600001'
      and (r->0->>'first_purchase_at')::timestamptz = tat and (r->0->>'last_purchase_at')::timestamptz = tat + interval '1 day', (r->0)::text);
    perform pg_temp.chk('top_customers: tie broken by customer id (Tie A paid 1,000, Tie B paid 400 - collected does not matter)', r->1->>'customer_id' = 'aaaaaaaa-0000-0000-0000-000000000001' and r->2->>'customer_id' = 'bbbbbbbb-0000-0000-0000-000000000001');
    perform pg_temp.chk('top_customers: limit 2 -> 2 rows; limit 0 clamps to 1 row', jsonb_array_length(r2) = 2 and jsonb_array_length(r3) = 1);
    perform pg_temp.chk('top_customers: address-less customer has null area/pincode', (r->3->>'area') is null and (r->3->>'pincode') is null);
  end;

  -- ===== customer_totals_new_vs_repeat =====
  declare oct2 uuid := pg_temp.mkorg('custtot'); mct uuid; cx uuid; cy uuid; cz uuid; cw uuid; tat timestamptz := timestamptz '2026-10-15 12:00:00+05:30';
  begin
    mct := pg_temp.mkuser('master', oct2);
    cx := pg_temp.mkcust(oct2, 'X repeat', timestamptz '2026-08-01 10:00:00+05:30');
    cy := pg_temp.mkcust(oct2, 'Y new', timestamptz '2026-10-05 10:00:00+05:30');
    cz := pg_temp.mkcust(oct2, 'Z no purchase', timestamptz '2026-10-10 10:00:00+05:30');
    cw := pg_temp.mkcust(oct2, 'W old', timestamptz '2026-08-01 10:00:00+05:30');
    perform pg_temp.mkinv(oct2, cx, 'product', 1000, 0, 180, 1180, 1180, timestamptz '2026-08-20 12:00:00+05:30');   -- before the window
    perform pg_temp.mkinv(oct2, cx, 'product', 1000, 0, 180, 1180, 1180, tat);
    perform pg_temp.mkinv(oct2, cy, 'rent', 500, 0, 90, 590, 590, tat);
    -- W's only invoice is before the window, so W is not a buyer in October
    perform pg_temp.mkinv(oct2, cw, 'product', 100, 0, 18, 118, 118, timestamptz '2026-09-30 23:50:00+05:30');
    perform pg_temp.as_user(mct);
    r := public.report_customer_totals(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    -- total 4, created in window 2 (Y, Z), buyers 2 (X, Y), X is repeat (invoice Aug 20), Y new => 50.0%, avg (1,180 + 590) / 2 = 885
    perform pg_temp.chk('customer_totals_new_vs_repeat', pg_temp.n(r,'{total_customers}')=4 and pg_temp.n(r,'{new_customers}')=2 and pg_temp.n(r,'{buying_customers}')=2 and pg_temp.n(r,'{new_buyers}')=1
      and pg_temp.n(r,'{repeat_buyers}')=1 and pg_temp.n(r,'{repeat_rate_percent}')=50.0 and pg_temp.n(r,'{avg_revenue_per_buyer}')=885, r::text);
    perform pg_temp.as_user(mct);
    r := public.report_customer_totals(date '2026-01-01', date '2026-01-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('customer_totals: no buyers -> repeat rate null, average 0', r->>'repeat_rate_percent' is null and pg_temp.n(r,'{avg_revenue_per_buyer}')=0 and pg_temp.n(r,'{buying_customers}')=0, r::text);
  end;

  -- ===== row_cap_gone: 1,100 invoices + items + customers in one month (the browser path stopped at 1,000) =====
  declare ov uuid := pg_temp.mkorg('volume'); mv uuid; pv uuid; tat timestamptz := timestamptz '2026-06-15 12:00:00+05:30'; br uuid; md uuid;
  begin
    mv := pg_temp.mkuser('master', ov);
    insert into public.brands (org_id, name, category) values (ov, 'b', 'ro') returning id into br;
    insert into public.models (org_id, brand_id, name) values (ov, br, 'm') returning id into md;
    insert into public.products (org_id, brand_id, model_id, name, category, price) values (ov, br, md, 'Vol product', 'ro', 100) returning id into pv;
    insert into public.customers (id, org_id, name, mobile, created_at)
      select ('00000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid, ov, 'Vol ' || g, lpad(g::text, 10, '0'), tat from generate_series(1, 1100) g;
    insert into public.invoices (id, org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at, updated_at)
      select ('00000000-0000-4000-9000-' || lpad(g::text, 12, '0'))::uuid, ov, ('00000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid, 'product', 100, 0, 18, 118, 'paid', 118, tat, tat from generate_series(1, 1100) g;
    insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost, created_at, updated_at)
      select ov, ('00000000-0000-4000-9000-' || lpad(g::text, 12, '0'))::uuid, 'product', pv, 1, 100, 0, 60, tat, tat from generate_series(1, 1100) g;
    perform pg_temp.as_user(mv);
    r := public.report_sales_service(date '2026-06-01', date '2026-06-30');
    r2 := public.report_pnl(date '2026-06-01', date '2026-06-30');
    r3 := public.report_top_customers(date '2026-06-01', date '2026-06-30', 1000);
    perform pg_temp.as_pg();
    -- 1,100 x 118 = 129,800 ; gst 1,100 x 18 = 19,800 ; qty 1,100
    perform pg_temp.chk('row_cap_gone: 1,100 invoices -> count 1,100, total 129,800, GST 19,800, qty 1,100 (a 1,000-row cap would give 118,000)',
      pg_temp.n(r,'{by_class,sales,count}')=1100 and pg_temp.n(r,'{totals,total}')=129800 and pg_temp.n(r,'{totals,gst}')=19800 and pg_temp.n(r,'{totals,collected}')=129800 and pg_temp.n(r,'{by_class,sales,qty}')=1100, (r->'totals')::text);
    perform pg_temp.chk('row_cap_gone: P&L item profit over 1,100 items (revenue 110,000, cost 66,000)', pg_temp.n(r2,'{item_profit,revenue}')=110000 and pg_temp.n(r2,'{item_profit,cost}')=66000 and pg_temp.n(r2,'{invoiced,total}')=129800, (r2->'item_profit')::text);
    perform pg_temp.chk('row_cap_gone: top customers limit 1000 is clamped to 200 rows, all 118', jsonb_array_length(r3) = 200 and pg_temp.n(r3,'{0,invoiced_total}')=118 and pg_temp.n(r3,'{199,rank}')=200, jsonb_array_length(r3)::text);
    perform pg_temp.as_user(mv);
    r := public.report_customer_totals(date '2026-06-01', date '2026-06-30');
    r2 := public.report_product_sales(date '2026-06-01', date '2026-06-30');
    perform pg_temp.as_pg();
    perform pg_temp.chk('row_cap_gone: customer totals count 1,100 customers / buyers; product sales qty 1,100', pg_temp.n(r,'{total_customers}')=1100 and pg_temp.n(r,'{buying_customers}')=1100 and pg_temp.n(r,'{new_customers}')=1100
      and pg_temp.n(r2,'{0,qty}')=1100 and pg_temp.n(r2,'{0,invoice_count}')=1100 and pg_temp.n(r2,'{0,revenue}')=110000, r::text);
  end;

  -- ===== acl_proacl_exact =====
  declare bad text := ''; f record;
  begin
    for f in
      select p.oid, p.proname, coalesce((select string_agg(distinct case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end, ',' order by case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end)
                                         from aclexplode(p.proacl) a), 'NULL(default PUBLIC)') as grantees, p.prosecdef, p.provolatile, p.proconfig::text as cfg
      from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'report\_%' or p.proname like '\_report\_%')
    loop
      if f.proname in ('_report_org', '_report_ist_start', '_report_invoice_base') then
        if f.grantees <> 'postgres' then bad := bad || f.proname || '=' || f.grantees || ' '; end if;
      else
        if f.grantees <> 'authenticated,postgres,service_role' then bad := bad || f.proname || '=' || f.grantees || ' '; end if;
        if not f.prosecdef or f.provolatile <> 's' or f.cfg not like '%search_path=public%' then bad := bad || f.proname || ' not definer/stable/search_path '; end if;
      end if;
    end loop;
    perform pg_temp.chk('acl_proacl_exact: report_* = {postgres, authenticated, service_role} (no anon, no PUBLIC) and SECURITY DEFINER STABLE search_path=public; helpers = {postgres} only', bad = '', bad);
    perform pg_temp.chk('acl_proacl_exact: 5 report functions + 3 helpers exist (migrations 2-3 add more later)', (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
      ('report_sales_service','report_pnl','report_top_customers','report_customer_totals','report_product_sales','_report_org','_report_ist_start','_report_invoice_base')) = 8);
  end;
  -- anon really cannot execute
  declare ea text;
  begin
    begin execute 'set local role anon'; perform public.report_sales_service(date '2026-10-01', date '2026-10-31'); ea := 'NO ERROR';
    exception when others then ea := sqlerrm; end;
    perform pg_temp.as_pg();
    perform pg_temp.chk('acl_proacl_exact: anon gets permission denied', ea like 'permission denied%', ea);
  end;

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
