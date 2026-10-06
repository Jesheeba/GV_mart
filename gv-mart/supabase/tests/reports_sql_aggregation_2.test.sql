-- Rolled-back DB tests for migration 20261009110000 (reports SQL aggregation 2): report_coverage.
-- Run with the migration applied (or concatenated in front of this file). Throwaway "__TEST_" organisations,
-- ends in a RAISE. Hand-written expected constants, see the comments next to the fixtures.
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
  o uuid; m uuid; t1 uuid; t2 uuid; c uuid; r jsonb; r2 jsonb;
  brand uuid; model uuid; prod uuid; planA uuid; planB uuid; rplan uuid;
  tkw uuid; tka uuid; tkr uuid; tkp uuid; v_inst uuid; i1 uuid;
begin
  o := pg_temp.mkorg('coverage');
  if (select name from organizations where id = o) not like '\_\_TEST\_%' then raise exception 'refusing to run outside a __TEST_ org'; end if;
  m := pg_temp.mkuser('master', o);
  t1 := pg_temp.mktech(o); t2 := pg_temp.mktech(o);
  c := pg_temp.mkcust(o, 'Cov');
  insert into public.brands (org_id, name, category) values (o, 'b', 'ro') returning id into brand;
  insert into public.models (org_id, brand_id, name) values (o, brand, 'm') returning id into model;
  insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'P', 'ro', 100) returning id into prod;
  -- AMC plans: A = 2,400 over 2 years -> 1,200/yr -> 100 a month ; B = price_per_year 600 -> 50 a month
  insert into public.amc_plans (org_id, name, years, price) values (o, 'A', 2, 2400) returning id into planA;
  insert into public.amc_plans (org_id, name, years, price, price_per_year) values (o, 'B', 1, 600, 600) returning id into planB;
  insert into public.rental_plans (org_id, name, yearly_rate) values (o, 'R', 3600) returning id into rplan;
  -- contracts (range under test: Sep + Oct 2026)
  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date) values
    (o, c, prod, planA, date '2026-09-15', date '2027-09-14'),   -- Sep + Oct, 100 each
    (o, c, prod, planB, date '2026-10-10', date '2026-12-31'),   -- Oct only, 50
    (o, c, prod, planA, date '2026-11-01', date '2027-10-31'),   -- starts after Oct 31: neither
    (o, c, prod, planA, date '2025-01-01', date '2026-08-31'),   -- expired before Sep 1: neither
    (o, c, prod, planB, date '2025-01-01', date '2026-09-01');   -- expires Sep 1: Sep only, 50
  insert into public.warranties (org_id, customer_id, product_id, start_date, expiry_date) values
    (o, c, prod, date '2026-08-01', date '2026-09-30'),          -- Sep only
    (o, c, prod, date '2026-10-31', date '2027-10-30'),          -- Oct only
    (o, c, prod, date '2026-01-01', date '2026-12-31');          -- both
  insert into public.rental_contracts (org_id, customer_id, product_id, plan_id, start_date, returned_at) values
    (o, c, prod, rplan, date '2026-08-01', null),                                                  -- both months
    (o, c, prod, rplan, date '2026-09-05', timestamptz '2026-09-20 12:00:00+05:30'),               -- Sep only
    (o, c, prod, rplan, date '2026-09-05', timestamptz '2026-10-01 00:30:00+05:30'),               -- returned 00:30 IST Oct 1 (= Sep 30 UTC): IST date Oct 1 -> still out in Oct
    (o, c, prod, rplan, date '2026-11-01', null);                                                  -- starts after Oct 31: neither
  -- visits by ticket type; every instant is an explicit IST time
  tkw := pg_temp.mkticket(o, c, 'warranty', null); tka := pg_temp.mkticket(o, c, 'amc', null); tkr := pg_temp.mkticket(o, c, 'rental', null); tkp := pg_temp.mkticket(o, c, 'paid', null);
  perform pg_temp.mkvisit(o, tkw, t1, timestamptz '2026-10-01 00:30:00+05:30', 0);   -- Oct (UTC says Sep 30)
  perform pg_temp.mkvisit(o, tkw, t1, timestamptz '2026-09-30 23:50:00+05:30', 0);   -- Sep
  perform pg_temp.mkvisit(o, tkw, t1, timestamptz '2026-10-31 23:50:00+05:30', 0);   -- Oct
  perform pg_temp.mkvisit(o, tkw, t1, timestamptz '2026-11-01 00:30:00+05:30', 0);   -- outside Sep..Oct
  perform pg_temp.mkvisit(o, tka, t1, timestamptz '2026-10-15 12:00:00+05:30', 0);
  perform pg_temp.mkvisit(o, tkr, t1, timestamptz '2026-09-10 12:00:00+05:30', 0);
  perform pg_temp.mkvisit(o, tkr, t1, timestamptz '2026-09-11 12:00:00+05:30', 0);
  v_inst := pg_temp.mkvisit(o, tkp, t1, timestamptz '2026-10-20 12:00:00+05:30', 0);   -- a plain paid visit: only counts in the installation "visits"
  -- installs: t1 2 (Oct 5), t2 3 (23:50 IST Sep 30); outside: 7 at 00:30 IST Nov 1
  insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty, created_at) values
    (o, v_inst, t1, prod, 2, timestamptz '2026-10-05 12:00:00+05:30'), (o, v_inst, t2, prod, 3, timestamptz '2026-09-30 23:50:00+05:30'),
    (o, v_inst, t1, prod, 7, timestamptz '2026-11-01 00:30:00+05:30');
  -- 10 product units sold in the range (+ 5 outside it, and 4 spare units which never count)
  i1 := pg_temp.mkinv(o, c, 'product', 1000, 0, 180, 1180, 1180, timestamptz '2026-10-02 12:00:00+05:30');
  perform pg_temp.mkitem(o, i1, 'product', prod, 6, 100, 0, 50, timestamptz '2026-10-02 12:00:00+05:30');
  perform pg_temp.mkitem(o, i1, 'product', prod, 4, 100, 0, 50, timestamptz '2026-09-30 23:50:00+05:30');
  perform pg_temp.mkitem(o, i1, 'product', prod, 5, 100, 0, 50, timestamptz '2026-11-01 00:30:00+05:30');
  perform pg_temp.mkitem(o, i1, 'spare', gen_random_uuid(), 4, 100, 0, 50, timestamptz '2026-10-02 12:00:00+05:30');

  perform pg_temp.as_user(m);
  r := public.report_coverage(date '2026-09-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('coverage_ist_months: two months, Sep then Oct, not truncated', jsonb_array_length(r->'months') = 2 and r->'months'->0->>'month' = '2026-09' and r->'months'->1->>'month' = '2026-10' and (r->>'truncated')::boolean = false, (r->'months')::text);
  -- warranty: visits Sep 1 / Oct 2 (00:30 IST Oct 1 and 23:50 IST Oct 31) ; active Sep 2 (W1, W3) / Oct 2 (W2, W3)
  perform pg_temp.chk('coverage_ist_months: warranty visits land in IST months (00:30 IST Oct 1 is October, 23:50 IST Sep 30 is September)',
    pg_temp.n(r,'{months,0,warranty,visits}')=1 and pg_temp.n(r,'{months,1,warranty,visits}')=2, (r->'months')::text);
  perform pg_temp.chk('coverage_ist_months: warranty active overlap (Sep 2, Oct 2)', pg_temp.n(r,'{months,0,warranty,active}')=2 and pg_temp.n(r,'{months,1,warranty,active}')=2);
  -- amc: visits 0 / 1 ; Sep active 2 (100 + 50 = 150) ; Oct active 2 (100 + 50 = 150)
  perform pg_temp.chk('coverage_ist_months: AMC visits, active and plan value (price/years/12 and price_per_year/12)',
    pg_temp.n(r,'{months,0,amc,visits}')=0 and pg_temp.n(r,'{months,1,amc,visits}')=1 and pg_temp.n(r,'{months,0,amc,active}')=2 and pg_temp.n(r,'{months,1,amc,active}')=2
    and pg_temp.n(r,'{months,0,amc,plan_value}')=150 and pg_temp.n(r,'{months,1,amc,plan_value}')=150, (r->'months')::text);
  -- rental: visits 2 / 0 ; Sep active 3 (900) ; Oct active 2 (600): R3 returned 00:30 IST Oct 1 is still out in October
  perform pg_temp.chk('coverage_ist_months: rental visits, active, value; return at 00:30 IST Oct 1 compares as the IST date',
    pg_temp.n(r,'{months,0,rental,visits}')=2 and pg_temp.n(r,'{months,1,rental,visits}')=0 and pg_temp.n(r,'{months,0,rental,active}')=3 and pg_temp.n(r,'{months,1,rental,active}')=2
    and pg_temp.n(r,'{months,0,rental,plan_value}')=900 and pg_temp.n(r,'{months,1,rental,plan_value}')=600, (r->'months')::text);
  -- installation: installs 5 ; units sold 10 ; visits in range 7 (warranty 3 + amc 1 + rental 2 + paid 1) ; technicians {t1,t2} = 2 ; months 2
  perform pg_temp.chk('coverage installation: totals', pg_temp.n(r,'{installation,installs}')=5 and pg_temp.n(r,'{installation,units_sold}')=10 and pg_temp.n(r,'{installation,visits}')=7
    and pg_temp.n(r,'{installation,technician_count}')=2 and pg_temp.n(r,'{installation,months_count}')=2, (r->'installation')::text);
  -- per tech per month 5 / 2 / 2 = 1.25 ; per product sold 5 / 10 = 0.5 ; per visit 5 / 7 = 0.71
  perform pg_temp.chk('coverage installation: rates', pg_temp.n(r,'{installation,per_technician_per_month}')=1.25 and pg_temp.n(r,'{installation,per_product_sold}')=0.5 and pg_temp.n(r,'{installation,per_visit}')=0.71, (r->'installation')::text);
  perform pg_temp.chk('coverage installation: by technician, installs desc (t2 3 -> 1.5/month, t1 2 -> 1/month)', r->'installation'->'by_technician'->0->>'technician_id' = t2::text and pg_temp.n(r,'{installation,by_technician,0,installs}')=3
    and pg_temp.n(r,'{installation,by_technician,0,per_month}')=1.5 and r->'installation'->'by_technician'->1->>'technician_id' = t1::text and pg_temp.n(r,'{installation,by_technician,1,per_month}')=1, (r->'installation'->'by_technician')::text);

  -- 36-month cap: 40 months asked, newest 36 kept (Nov 2023 .. Oct 2026), truncated = true, months_count capped at 36
  perform pg_temp.as_user(m);
  r2 := public.report_coverage(date '2023-07-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('coverage_ist_months: 40-month range keeps the newest 36 and says truncated', jsonb_array_length(r2->'months') = 36 and r2->'months'->0->>'month' = '2023-11' and r2->'months'->35->>'month' = '2026-10'
    and (r2->>'truncated')::boolean and pg_temp.n(r2,'{installation,months_count}')=36, (r2->'months'->0->>'month'));
  perform pg_temp.as_user(m);
  r := public.report_coverage(date '2023-11-01', date '2026-10-31');
  r2 := public.report_coverage(date '2026-10-15', date '2026-10-15');
  perform pg_temp.as_pg();
  perform pg_temp.chk('coverage: exactly 36 months is not truncated; one day is one month', jsonb_array_length(r->'months') = 36 and not (r->>'truncated')::boolean and jsonb_array_length(r2->'months') = 1 and r2->'months'->0->>'month' = '2026-10');
  perform pg_temp.as_user(m);
  r := public.report_coverage(date '2026-10-31', date '2026-10-01');
  perform pg_temp.as_pg();
  perform pg_temp.chk('coverage: from > to inside one month still returns that month', jsonb_array_length(r->'months') = 1, jsonb_array_length(r->'months')::text);
  perform pg_temp.as_user(m);
  r := public.report_coverage(date '2026-10-31', date '2026-09-01');
  perform pg_temp.as_pg();
  perform pg_temp.chk('coverage: reversed range spanning months gives no months and months_count 1', jsonb_array_length(r->'months') = 0 and pg_temp.n(r,'{installation,months_count}') = 1, r::text);

  -- gates
  declare e text; techuser uuid := pg_temp.mkuser('technician', o);
  begin
    begin perform pg_temp.as_user(techuser); perform public.report_coverage(date '2026-09-01', date '2026-10-31'); e := 'NO ERROR'; exception when others then e := sqlerrm; end;
    perform pg_temp.as_pg();
    perform pg_temp.chk('coverage: technician rejected', e like 'not permitted%', e);
    begin execute 'set local role anon'; perform public.report_coverage(date '2026-09-01', date '2026-10-31'); e := 'NO ERROR'; exception when others then e := sqlerrm; end;
    perform pg_temp.as_pg();
    perform pg_temp.chk('coverage: anon permission denied', e like 'permission denied%', e);
  end;
  declare o2 uuid := pg_temp.mkorg('cov_other'); m2 uuid := pg_temp.mkuser('master', o2);
  begin
    perform pg_temp.as_user(m2);
    r := public.report_coverage(date '2026-09-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('coverage cross-org: another organisation sees zeros', pg_temp.n(r,'{installation,installs}')=0 and pg_temp.n(r,'{months,0,amc,active}')=0 and pg_temp.n(r,'{months,1,rental,active}')=0 and pg_temp.n(r,'{months,0,warranty,visits}')=0, r::text);
  end;
  declare bad text := ''; f record;
  begin
    for f in select p.proname, coalesce((select string_agg(distinct case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end, ',' order by case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end) from aclexplode(p.proacl) a), 'NULL') g, p.prosecdef, p.provolatile, p.proconfig::text cfg
             from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'report_coverage' loop
      if f.g <> 'authenticated,postgres,service_role' or not f.prosecdef or f.provolatile <> 's' or f.cfg not like '%search_path=public%' then bad := bad || f.proname || '=' || f.g; end if;
    end loop;
    perform pg_temp.chk('acl_proacl_exact: report_coverage = {postgres, authenticated, service_role}, SECURITY DEFINER STABLE search_path=public', bad = '' and exists (select 1 from pg_proc where proname = 'report_coverage'), bad);
  end;

  select string_agg(r3.line, E'\n' order by r3.n) into txt from pg_temp.res r3;
  raise exception E'RESULTS\n%', txt;
end $t$;
