-- Rolled-back DB tests for report_sales_service.by_kind (batch-17 item 7, docs/sales-invoices-kpi-design.md).
-- Run with the migration text concatenated in front of this file. Everything runs in two throwaway "__TEST_" organisations
-- and ends in a RAISE, so nothing is kept and no purge is needed. Expected values are hand-computed (comments beside the fixtures).
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
-- call report_sales_service as a user; an error comes back as {"error": "..."} so tests can assert on it
create function pg_temp.rss(p_uid uuid, p_from date, p_to date) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_user(p_uid);
  begin r := public.report_sales_service(p_from, p_to);
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
  o uuid; o2 uuid; m uuid; m2 uuid; tcu uuid; tech uuid;
  cA uuid; cB uuid; cD uuid; cT uuid; cX uuid;
  i6 uuid; i7 uuid; tk6 uuid; tk7 uuid;
  r jsonb; r1 jsonb; r2 jsonb; r3 jsonb; rb jsonb;
  fp1 text; fp2 text; ea text;
begin
  select md5(coalesce(string_agg(id::text || total::text || amount_paid::text, ',' order by id), '')) into fp1 from public.invoices
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  o := pg_temp.mkorg('a');
  if (select name from organizations where id = o) not like '\_\_TEST\_%' then raise exception 'refusing to run outside a __TEST_ org'; end if;
  o2 := pg_temp.mkorg('b');
  m := pg_temp.mkuser('master', o);
  tcu := pg_temp.mkuser('technician', o);
  m2 := pg_temp.mkuser('master', o2);
  insert into public.technicians (org_id, profile_id) values (o, tcu) returning id into tech;
  cA := pg_temp.mkcust(o, 'Alpha'); cB := pg_temp.mkcust(o, 'Bravo'); cD := pg_temp.mkcust(o, 'Delta');
  cT := pg_temp.mkcust(o, 'Flagged', true);
  cX := pg_temp.mkcust(o2, 'Other org');

  -- ===== ORG A, October 2026 (explicit IST instants) =====
  -- product : 11,210 (gst 1,710, paid 11,210) + 5,900 (900, paid 2,000) + 118 (18, paid 118; Oct 1 00:30 IST) + 236 (36, paid 236; Oct 31 23:50 IST)
  perform pg_temp.mkinv(o, cA, 'product', 1710, 11210, 11210, timestamptz '2026-10-05 12:00:00+05:30');
  perform pg_temp.mkinv(o, cB, 'product', 900, 5900, 2000, timestamptz '2026-10-06 12:00:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 18, 118, 118, timestamptz '2026-10-01 00:30:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 36, 236, 236, timestamptz '2026-10-31 23:50:00+05:30');
  -- outside October (IST): Sep 30 23:50 and Nov 1 00:30
  perform pg_temp.mkinv(o, cA, 'product', 54, 354, 0, timestamptz '2026-09-30 23:50:00+05:30');
  perform pg_temp.mkinv(o, cA, 'product', 72, 472, 0, timestamptz '2026-11-01 00:30:00+05:30');
  -- amc 2,360 (360) paid ; rent 590 (90) paid
  perform pg_temp.mkinv(o, cA, 'amc', 360, 2360, 2360, timestamptz '2026-10-07 12:00:00+05:30');
  perform pg_temp.mkinv(o, cB, 'rent', 90, 590, 590, timestamptz '2026-10-08 12:00:00+05:30');
  -- counter spare sale 1,180 (180) due (paid 0)
  perform pg_temp.mkinv(o, cD, 'spare', 180, 1180, 0, timestamptz '2026-10-09 12:00:00+05:30');
  -- technician SERVICE invoice: spare type, linked to a ticket that has a visit: 1,062 (162) paid  -> NOT a spare
  i6 := pg_temp.mkinv(o, cD, 'spare', 162, 1062, 1062, timestamptz '2026-10-10 12:00:00+05:30');
  tk6 := pg_temp.mkticket(o, cD, i6, 'completed', 'normal', null, timestamptz '2026-10-10 10:00:00+05:30', timestamptz '2026-10-10 12:00:00+05:30');
  perform pg_temp.mkvisit(o, tk6, tech, timestamptz '2026-10-10 10:30:00+05:30', 500);
  -- spare-type invoice linked to a ticket with NO visit: counts as a counter spare sale 590 (90) paid 590
  i7 := pg_temp.mkinv(o, cD, 'spare', 90, 590, 590, timestamptz '2026-10-11 12:00:00+05:30');
  tk7 := pg_temp.mkticket(o, cD, i7, 'open', 'normal', null, timestamptz '2026-10-11 10:00:00+05:30', timestamptz '2026-10-11 12:00:00+05:30');
  -- flagged test customer: product 9,999 must not appear anywhere
  perform pg_temp.mkinv(o, cT, 'product', 0, 9999, 9999, timestamptz '2026-10-12 12:00:00+05:30');
  -- other organisation: product 7,777 must not leak into org A
  perform pg_temp.mkinv(o2, cX, 'product', 0, 7777, 7777, timestamptz '2026-10-05 12:00:00+05:30');

  r := pg_temp.rss(m, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('by_kind present with the 5 keys', (select array_agg(x order by x) from jsonb_object_keys(r->'by_kind') x) = array['amc','product','rental','service','spare_counter'], (r->'by_kind')::text);
  -- product: 4 invoices, 11210+5900+118+236 = 17,464; gst 1710+900+18+36 = 2,664; collected 11210+2000+118+236 = 13,564
  perform pg_temp.chk('product count 4', pg_temp.n(r,'{by_kind,product,count}') = 4, (r->'by_kind'->'product')::text);
  perform pg_temp.chk('product total 17,464', pg_temp.n(r,'{by_kind,product,total}') = 17464);
  perform pg_temp.chk('product gst 2,664', pg_temp.n(r,'{by_kind,product,gst}') = 2664);
  perform pg_temp.chk('product collected 13,564', pg_temp.n(r,'{by_kind,product,collected}') = 13564);
  -- spare_counter: 1,180 (due) + 590 (ticket without a visit) = 1,770; count 2; gst 270; collected 590
  perform pg_temp.chk('spare_counter count 2 / total 1,770 / gst 270 / collected 590',
    pg_temp.n(r,'{by_kind,spare_counter,count}') = 2 and pg_temp.n(r,'{by_kind,spare_counter,total}') = 1770
    and pg_temp.n(r,'{by_kind,spare_counter,gst}') = 270 and pg_temp.n(r,'{by_kind,spare_counter,collected}') = 590, (r->'by_kind'->'spare_counter')::text);
  -- service: only the technician service invoice 1,062 (162) paid 1,062
  perform pg_temp.chk('technician service invoice is kind service, NOT spare',
    pg_temp.n(r,'{by_kind,service,count}') = 1 and pg_temp.n(r,'{by_kind,service,total}') = 1062 and pg_temp.n(r,'{by_kind,service,collected}') = 1062, (r->'by_kind'->'service')::text);
  perform pg_temp.chk('amc 1 / 2,360 / 360 / 2,360',
    pg_temp.n(r,'{by_kind,amc,count}') = 1 and pg_temp.n(r,'{by_kind,amc,total}') = 2360 and pg_temp.n(r,'{by_kind,amc,gst}') = 360 and pg_temp.n(r,'{by_kind,amc,collected}') = 2360);
  perform pg_temp.chk('rental 1 / 590 / 90 / 590',
    pg_temp.n(r,'{by_kind,rental,count}') = 1 and pg_temp.n(r,'{by_kind,rental,total}') = 590 and pg_temp.n(r,'{by_kind,rental,gst}') = 90 and pg_temp.n(r,'{by_kind,rental,collected}') = 590);
  perform pg_temp.chk('flagged test customer excluded and other org not leaked (product total is exactly 17,464)',
    pg_temp.n(r,'{by_kind,product,total}') = 17464);

  -- parity: by_kind sums equal totals; existing keys unchanged
  perform pg_temp.chk('PARITY by_kind counts sum to totals.count (9)', (select sum((e.v->>'count')::numeric) from jsonb_each(r->'by_kind') e(k, v)) = pg_temp.n(r,'{totals,count}') and pg_temp.n(r,'{totals,count}') = 9);
  perform pg_temp.chk('PARITY by_kind totals sum to totals.total (23,246)', (select sum((e.v->>'total')::numeric) from jsonb_each(r->'by_kind') e(k, v)) = pg_temp.n(r,'{totals,total}') and pg_temp.n(r,'{totals,total}') = 23246);
  perform pg_temp.chk('PARITY by_kind gst and collected sum to totals',
    (select sum((e.v->>'gst')::numeric) from jsonb_each(r->'by_kind') e(k, v)) = pg_temp.n(r,'{totals,gst}')
    and (select sum((e.v->>'collected')::numeric) from jsonb_each(r->'by_kind') e(k, v)) = pg_temp.n(r,'{totals,collected}'));
  perform pg_temp.chk('PARITY by_class sales = product + spare_counter (19,234); service, amc, rental match',
    pg_temp.n(r,'{by_class,sales,total}') = pg_temp.n(r,'{by_kind,product,total}') + pg_temp.n(r,'{by_kind,spare_counter,total}')
    and pg_temp.n(r,'{by_class,service,total}') = pg_temp.n(r,'{by_kind,service,total}')
    and pg_temp.n(r,'{by_class,amc,total}') = pg_temp.n(r,'{by_kind,amc,total}')
    and pg_temp.n(r,'{by_class,rental,total}') = pg_temp.n(r,'{by_kind,rental,total}')
    and pg_temp.n(r,'{by_class,sales,total}') = 19234);
  perform pg_temp.chk('existing keys still present',
    r ?& array['by_class','totals','by_invoice_type','service_visits','calls','technicians','avg_value_per_service_call']);

  -- ===== IST day windows =====
  r1 := pg_temp.rss(m, date '2026-10-10', date '2026-10-10');
  perform pg_temp.chk('DAY Oct 10 (IST): only the service invoice',
    pg_temp.n(r1,'{by_kind,service,total}') = 1062 and pg_temp.n(r1,'{by_kind,product,count}') = 0 and pg_temp.n(r1,'{by_kind,spare_counter,count}') = 0, r1::text);
  r2 := pg_temp.rss(m, date '2026-10-01', date '2026-10-01');
  perform pg_temp.chk('DAY Oct 1 includes the 00:30 IST invoice (it is Sep 30 in UTC)', pg_temp.n(r2,'{by_kind,product,count}') = 1 and pg_temp.n(r2,'{by_kind,product,total}') = 118, r2::text);
  r3 := pg_temp.rss(m, date '2026-10-31', date '2026-10-31');
  perform pg_temp.chk('DAY Oct 31 includes the 23:50 IST invoice', pg_temp.n(r3,'{by_kind,product,count}') = 1 and pg_temp.n(r3,'{by_kind,product,total}') = 236, r3::text);
  perform pg_temp.chk('DAY Nov 1 has only the 00:30 IST invoice (472)', pg_temp.n(pg_temp.rss(m, date '2026-11-01', date '2026-11-01'),'{by_kind,product,total}') = 472);
  rb := pg_temp.rss(m, date '2026-12-01', date '2026-12-31');
  perform pg_temp.chk('EMPTY window: all five kinds present with zeros',
    (select count(*) from jsonb_each(rb->'by_kind') e(k, v) where (e.v->>'count')::numeric = 0 and (e.v->>'total')::numeric = 0) = 5, (rb->'by_kind')::text);

  -- ===== other organisation sees only its own =====
  r2 := pg_temp.rss(m2, date '2026-10-01', date '2026-10-31');
  perform pg_temp.chk('ORG isolation: org B master sees only org B (product 7,777, nothing else)',
    pg_temp.n(r2,'{by_kind,product,total}') = 7777 and pg_temp.n(r2,'{totals,total}') = 7777, r2::text);

  -- ===== access =====
  perform pg_temp.chk('ROLE technician refused', (pg_temp.rss(tcu, date '2026-10-01', date '2026-10-31')->>'error') is not null);
  begin
    execute 'set local role anon'; perform public.report_sales_service(date '2026-10-01', date '2026-10-31'); ea := 'NO ERROR';
  exception when others then ea := sqlerrm; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('ROLE anon: permission denied', ea like 'permission denied%', ea);

  -- ===== structure =====
  declare f record;
  begin
    select p.prosecdef, p.provolatile, p.proconfig::text as cfg, pg_get_function_arguments(p.oid) as args,
           coalesce((select string_agg(distinct case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end, ',' order by case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end)
                     from aclexplode(p.proacl) a), 'NULL(default PUBLIC)') as grantees
      into f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'report_sales_service';
    perform pg_temp.chk('STRUCT: signature unchanged (p_from date, p_to date)', f.args = 'p_from date, p_to date', f.args);
    perform pg_temp.chk('STRUCT: SECURITY DEFINER, STABLE, fixed search_path = public', f.prosecdef and f.provolatile = 's' and f.cfg like '%search_path=public%', f.cfg);
    perform pg_temp.chk('STRUCT: EXECUTE = {authenticated, postgres, service_role}; PUBLIC and anon revoked', f.grantees = 'authenticated,postgres,service_role', f.grantees);
  end;
  perform pg_temp.chk('STRUCT: exactly one report_sales_service overload', (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'report_sales_service') = 1);

  select md5(coalesce(string_agg(id::text || total::text || amount_paid::text, ',' order by id), '')) into fp2 from public.invoices
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  perform pg_temp.chk('real-organisation invoices unchanged (fingerprint)', fp1 = fp2);

  select string_agg(x.line, E'\n' order by x.n) into txt from pg_temp.res x;
  raise exception E'RESULTS\n%', txt;
end $t$;
