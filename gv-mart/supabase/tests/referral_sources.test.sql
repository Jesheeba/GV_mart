-- Tests for 20261228100000_referral_sources.sql. Run ONLY as part of a rehearsal file
-- (begin; + migration + this file) -- the last block always RAISEs, so nothing persists.
-- Fixtures live in a throwaway __TEST_ org. Test names map to build-docs/features/referral-sources.md ACs.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create temp table fx (k text primary key, v uuid);
grant all on fx to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.fx(p_k text) returns uuid language sql as $f$ select v from pg_temp.fx where k = p_k $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.claims(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform pg_temp.claims(p_uid); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.mkcust(p_k text, p_mobile text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.customers (org_id, name, mobile) values (pg_temp.fx('org'), '__TEST_ ' || p_k, p_mobile) returning id into v;
  insert into pg_temp.fx values (p_k, v);
  return v;
end $f$;
grant execute on function pg_temp.chk(text, boolean, text), pg_temp.fx(text), pg_temp.mkuser(text, uuid), pg_temp.claims(uuid), pg_temp.as_user(uuid), pg_temp.as_pg(), pg_temp.mkcust(text, text) to public;

do $fx$
declare v_org uuid; v_org2 uuid;
begin
  insert into organizations (name) values ('__TEST_referral_sources_org') returning id into v_org;
  insert into organizations (name) values ('__TEST_referral_sources_org2') returning id into v_org2;
  insert into pg_temp.fx values ('org', v_org), ('org2', v_org2);
  if not exists (select 1 from settings where org_id = v_org) then
    insert into settings (org_id) values (v_org);
  end if;
  insert into pg_temp.fx values ('master', pg_temp.mkuser('master', v_org));
  insert into pg_temp.fx values ('sales', pg_temp.mkuser('sales_admin', v_org));
  insert into pg_temp.fx values ('ops', pg_temp.mkuser('operation_admin', v_org));
  perform pg_temp.mkcust('ref', '9000000701');      -- the referring customer
  perform pg_temp.mkcust('new1', '9000000702');     -- referred via a transaction
  perform pg_temp.mkcust('new2', '9000000703');     -- referred, then a second referrer tries
  perform pg_temp.mkcust('hist', '9000000704');     -- has paid purchase history
  perform pg_temp.mkcust('lead_c', '9000000705');   -- lead conversion target
  perform pg_temp.mkcust('staffref', '9000000706'); -- referred by staff
  perform pg_temp.mkcust('gone', '9000000707');     -- referrer that gets deleted
  perform pg_temp.mkcust('by_gone', '9000000708');
  perform pg_temp.mkcust('atomic', '9000000709');   -- failed sale target
  insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ other org', '9000000710') returning id into v_org2;
  insert into pg_temp.fx values ('foreign', v_org2);
  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (v_org, pg_temp.fx('hist'), 'product', 100, 0, 0, 100, 'paid', pg_temp.fx('master'));
end $fx$;

-- AC-6/AC-8 schema + guards
do $t$
declare v_err text;
begin
  perform pg_temp.chk('schema: customers + leads have referred_by_customer_id',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name in ('customers','leads') and column_name = 'referred_by_customer_id') = 2);
  perform pg_temp.chk('schema: points toggle defaults OFF / 0',
    (select not customer_referral_points_enabled and customer_referral_points = 0 from settings where org_id = pg_temp.fx('org')));

  begin
    update customers set referred_by_customer_id = pg_temp.fx('ref') where id = pg_temp.fx('new1');
    perform pg_temp.chk('AC-6 plain UPDATE of customer referrer is refused', false);
  exception when others then perform pg_temp.chk('AC-6 plain UPDATE of customer referrer is refused', sqlerrm like '%cannot be changed by a plain update%', sqlerrm); end;

  begin
    insert into customers (org_id, name, mobile, referred_by_customer_id) values (pg_temp.fx('org'), '__TEST_ x', '9000000799', pg_temp.fx('foreign'));
    perform pg_temp.chk('AC-8 cross-org customer referrer refused (customers)', false);
  exception when others then perform pg_temp.chk('AC-8 cross-org customer referrer refused (customers)', sqlerrm like '%same organisation%', sqlerrm); end;

  begin
    insert into leads (org_id, name, source, referred_by_customer_id) values (pg_temp.fx('org'), '__TEST_ lead x', 'referral', pg_temp.fx('foreign'));
    perform pg_temp.chk('AC-8 cross-org customer referrer refused (leads)', false);
  exception when others then perform pg_temp.chk('AC-8 cross-org customer referrer refused (leads)', sqlerrm like '%same organisation%', sqlerrm); end;

  begin
    insert into leads (org_id, name, source, customer_id, referred_by_customer_id) values (pg_temp.fx('org'), '__TEST_ lead self', 'referral', pg_temp.fx('ref'), pg_temp.fx('ref'));
    perform pg_temp.chk('AC-8 lead self-referral refused', false);
  exception when check_violation then perform pg_temp.chk('AC-8 lead self-referral refused', true); end;
end $t$;

-- AC-3/AC-6 New Customer with a customer referrer
do $t$
declare v_id uuid; v_ref uuid; v_at timestamptz;
begin
  perform pg_temp.as_user(pg_temp.fx('sales'));
  v_id := public.create_customer_with_referrer(pg_temp.fx('org'), null, 'other',
    jsonb_build_array(jsonb_build_object('name', '__TEST_ via form', 'mobile', '9000000720', 'is_primary', true)), '{}'::jsonb, null, pg_temp.fx('ref'));
  perform pg_temp.as_pg();
  select referred_by_customer_id, referred_at into v_ref, v_at from customers where id = v_id;
  perform pg_temp.chk('AC-6 create_customer_with_referrer links the customer referrer', v_ref = pg_temp.fx('ref') and v_at is not null);

  begin
    perform pg_temp.as_user(pg_temp.fx('ops'));
    perform public.create_customer_with_referrer(pg_temp.fx('org'), null, 'other',
      jsonb_build_array(jsonb_build_object('name', '__TEST_ ops', 'mobile', '9000000721', 'is_primary', true)), '{}'::jsonb, null, null);
    perform pg_temp.as_pg();
    perform pg_temp.chk('operation_admin cannot create customers (same as RLS)', false);
  exception when others then perform pg_temp.as_pg(); perform pg_temp.chk('operation_admin cannot create customers (same as RLS)', sqlerrm like '%only master or sales staff%', sqlerrm); end;

  begin
    perform pg_temp.as_user(pg_temp.fx('sales'));
    perform public.create_customer_with_referrer(pg_temp.fx('org'), null, 'other',
      jsonb_build_array(jsonb_build_object('name', '__TEST_ two', 'mobile', '9000000722', 'is_primary', true)), '{}'::jsonb, pg_temp.fx('master'), pg_temp.fx('ref'));
    perform pg_temp.as_pg();
    perform pg_temp.chk('two referrers at once refused', false);
  exception when others then perform pg_temp.as_pg(); perform pg_temp.chk('two referrers at once refused', sqlerrm like '%only one referrer%', sqlerrm); end;
end $t$;

-- AC-1/AC-6 transaction referrers (helper used by the Sale/Complaint/AMC wrappers)
do $t$
declare v_lead uuid; r record;
begin
  perform pg_temp.claims(pg_temp.fx('sales'));
  v_lead := public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('new1'), null, pg_temp.fx('ref'), null, null, 'Sale');
  select * into r from leads where id = v_lead;
  perform pg_temp.chk('AC-6 customer referrer: referral lead recorded with id + name/phone',
    r.source = 'referral' and r.status = 'won' and r.owner_id is null and r.referred_by_customer_id = pg_temp.fx('ref')
    and r.referred_by_name = '__TEST_ ref' and r.referred_by_phone = '9000000701' and r.customer_id = pg_temp.fx('new1'));
  perform pg_temp.chk('AC-6 customer referrer copied to the customer',
    (select referred_by_customer_id from customers where id = pg_temp.fx('new1')) = pg_temp.fx('ref'));

  perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('new2'), null, pg_temp.fx('ref'), null, null, 'Sale');
  perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('new2'), pg_temp.fx('master'), null, null, null, 'Sale');
  perform pg_temp.chk('first referrer wins on the customer; second still logged on its lead',
    (select referred_by_customer_id is not null and referred_by_user_id is null from customers where id = pg_temp.fx('new2'))
    and (select count(*) from leads where customer_id = pg_temp.fx('new2') and source = 'referral') = 2);

  perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('staffref'), pg_temp.fx('master'), null, null, null, 'AMC sale');
  perform pg_temp.chk('AC-1 staff referrer sets customers.referred_by_user_id (feeds existing staff bonus)',
    (select referred_by_user_id from customers where id = pg_temp.fx('staffref')) = pg_temp.fx('master'));

  v_lead := public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('hist'), null, null, '  Ravi  ', ' 9876543210 ', 'Service complaint');
  perform pg_temp.chk('AC-1 someone else: lead keeps trimmed name/phone, customer untouched',
    (select referred_by_name = 'Ravi' and referred_by_phone = '9876543210' from leads where id = v_lead)
    and (select referred_by_user_id is null and referred_by_customer_id is null from customers where id = pg_temp.fx('hist')));

  perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('hist'), null, pg_temp.fx('ref'), null, null, 'Sale');
  perform pg_temp.chk('customer with paid history: referrer logged on lead, NOT set on customer',
    (select referred_by_customer_id is null from customers where id = pg_temp.fx('hist')));

  perform pg_temp.chk('nothing picked: no lead', public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('hist'), null, null, '   ', null, 'Sale') is null);

  begin
    perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('ref'), null, pg_temp.fx('ref'), null, null, 'Sale');
    perform pg_temp.chk('AC-8 customer cannot refer themselves', false);
  exception when others then perform pg_temp.chk('AC-8 customer cannot refer themselves', sqlerrm like '%cannot refer themselves%', sqlerrm); end;

  begin
    perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('new1'), null, pg_temp.fx('foreign'), null, null, 'Sale');
    perform pg_temp.chk('AC-8 cross-org customer referrer refused (helper)', false);
  exception when others then perform pg_temp.chk('AC-8 cross-org customer referrer refused (helper)', sqlerrm like '%not found in this organisation%', sqlerrm); end;

  begin
    perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('new1'), pg_temp.fx('sales'), null, null, null, 'Sale');
    perform pg_temp.chk('AC-8 staff cannot refer as themselves', false);
  exception when others then perform pg_temp.chk('AC-8 staff cannot refer as themselves', sqlerrm like '%cannot refer yourself%', sqlerrm); end;
  perform pg_temp.as_pg();
end $t$;

-- AC-5 wrappers: technician path untouched, atomic with the billing RPC
do $t$
declare v_before int;
begin
  select count(*) into v_before from leads where customer_id = pg_temp.fx('atomic');
  perform pg_temp.as_user(pg_temp.fx('sales'));
  begin
    perform public.create_sale_with_referrer(pg_temp.fx('org'), pg_temp.fx('atomic'), '{}'::jsonb, null, 0, null, null, null, pg_temp.fx('ref'), null, null);
    perform pg_temp.as_pg();
    perform pg_temp.chk('AC-5 failed sale rolls back its referrer (atomic)', false, 'sale did not fail');
  exception when others then
    perform pg_temp.as_pg();
    perform pg_temp.chk('AC-5 failed sale rolls back its referrer (atomic)',
      sqlerrm like '%cart is empty%'
      and (select count(*) from leads where customer_id = pg_temp.fx('atomic')) = v_before
      and (select referred_by_customer_id is null from customers where id = pg_temp.fx('atomic')), sqlerrm);
  end;

  perform pg_temp.as_user(pg_temp.fx('sales'));
  begin
    perform public.create_sale_with_referrer(pg_temp.fx('org'), pg_temp.fx('atomic'), '{}'::jsonb, null, 0, gen_random_uuid(), null, null, pg_temp.fx('ref'), null, null);
    perform pg_temp.as_pg();
    perform pg_temp.chk('technician + another referrer refused', false);
  exception when others then perform pg_temp.as_pg(); perform pg_temp.chk('technician + another referrer refused', sqlerrm like '%only one referrer%', sqlerrm); end;

  perform pg_temp.as_user(pg_temp.fx('ops'));
  begin
    perform public.create_sale_with_referrer(pg_temp.fx('org'), pg_temp.fx('atomic'), '{}'::jsonb);
    perform pg_temp.as_pg();
    perform pg_temp.chk('wrapper keeps create_sale permission (ops refused)', false);
  exception when others then perform pg_temp.as_pg(); perform pg_temp.chk('wrapper keeps create_sale permission (ops refused)', sqlerrm like '%only master or sales_admin%', sqlerrm); end;
end $t$;

-- AC-6 lead conversion carry-over
do $t$
declare v_lead uuid;
begin
  insert into leads (org_id, name, mobile, source, customer_id, referred_by_customer_id)
    values (pg_temp.fx('org'), '__TEST_ lead c', '9000000705', 'referral', pg_temp.fx('lead_c'), pg_temp.fx('ref')) returning id into v_lead;
  perform pg_temp.claims(pg_temp.fx('sales'));
  perform public._carry_over_lead_referral(pg_temp.fx('org'), v_lead, pg_temp.fx('lead_c'), '9000000705', null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('AC-6 lead conversion carries the customer referrer',
    (select referred_by_customer_id from customers where id = pg_temp.fx('lead_c')) = pg_temp.fx('ref'), coalesce((select action from audit_log where row_id = v_lead order by created_at desc limit 1), ''));
  begin
    update customers set name = name where id = pg_temp.fx('lead_c');
    update customers set referred_by_customer_id = null where id = pg_temp.fx('lead_c');
    perform pg_temp.chk('bypass flag reset after carry-over', false);
  exception when others then perform pg_temp.chk('bypass flag reset after carry-over', sqlerrm like '%plain update%', sqlerrm); end;
end $t$;

-- AC-7 points: master toggle, once per referred customer, on a paid invoice
do $t$
declare v_inv uuid; v_n int; v_pts int;
begin
  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (pg_temp.fx('org'), pg_temp.fx('new1'), 'product', 100, 0, 0, 100, 'paid', pg_temp.fx('master'));
  perform pg_temp.chk('AC-7 toggle OFF: no points', (select count(*) from referral_points where ref_id = pg_temp.fx('new1')) = 0);

  update settings set customer_referral_points_enabled = true, customer_referral_points = 50 where org_id = pg_temp.fx('org');
  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (pg_temp.fx('org'), pg_temp.fx('new1'), 'spare', 10, 0, 0, 10, 'paid', pg_temp.fx('master'));
  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (pg_temp.fx('org'), pg_temp.fx('new1'), 'spare', 10, 0, 0, 10, 'paid', pg_temp.fx('master'));
  select count(*), sum(points) into v_n, v_pts from referral_points where ref_id = pg_temp.fx('new1') and source = 'customer_referral';
  perform pg_temp.chk('AC-7 toggle ON: exactly one award of the set amount to the referrer',
    v_n = 1 and v_pts = 50 and (select customer_id from referral_points where ref_id = pg_temp.fx('new1')) = pg_temp.fx('ref'), v_n || '/' || coalesce(v_pts, 0));

  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (pg_temp.fx('org'), pg_temp.fx('lead_c'), 'spare', 10, 0, 0, 10, 'due', pg_temp.fx('master')) returning id into v_inv;
  perform pg_temp.chk('AC-7 unpaid invoice: no points yet', (select count(*) from referral_points where ref_id = pg_temp.fx('lead_c')) = 0);
  update invoices set payment_status = 'paid' where id = v_inv;
  perform pg_temp.chk('AC-7 marked paid later: points awarded', (select count(*) from referral_points where ref_id = pg_temp.fx('lead_c')) = 1);

  insert into invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, sold_by)
    values (pg_temp.fx('org'), pg_temp.fx('staffref'), 'spare', 10, 0, 0, 10, 'paid', pg_temp.fx('master'));
  perform pg_temp.chk('AC-7 staff-referred customer: no customer points', (select count(*) from referral_points where ref_id = pg_temp.fx('staffref')) = 0);
end $t$;

-- referrer deleted -> link cleared, no error
do $t$
begin
  perform pg_temp.claims(pg_temp.fx('sales'));
  perform public._record_transaction_referrer(pg_temp.fx('org'), pg_temp.fx('by_gone'), null, pg_temp.fx('gone'), null, null, 'Sale');
  perform pg_temp.as_pg();
  delete from leads where referred_by_customer_id = pg_temp.fx('gone') and customer_id = pg_temp.fx('by_gone');
  delete from leads where customer_id = pg_temp.fx('gone');
  delete from customers where id = pg_temp.fx('gone');
  perform pg_temp.chk('deleting the referrer clears the link', (select referred_by_customer_id is null from customers where id = pg_temp.fx('by_gone')));
exception when others then perform pg_temp.as_pg(); perform pg_temp.chk('deleting the referrer clears the link', false, sqlerrm);
end $t$;

-- AC-9 grants + billing RPCs untouched
do $t$
declare v_sig text;
begin
  foreach v_sig in array array[
    'public.create_customer_with_referrer(uuid,text,text,jsonb,jsonb,uuid,uuid)',
    'public.create_sale_with_referrer(uuid,uuid,jsonb,uuid,integer,uuid,numeric,uuid,uuid,text,text)',
    'public.create_complaint_ticket_with_referrer(uuid,uuid,uuid,uuid,uuid,uuid,text,text,priority_level,ticket_channel,appointment_mode,boolean,date,uuid,uuid,text,uuid,jsonb,uuid,uuid,uuid,text,text)',
    'public.sell_amc_plan_with_referrer(uuid,uuid,uuid,uuid,date,integer,uuid,boolean,uuid,uuid,text,text)'] loop
    perform pg_temp.chk('AC-9 authenticated can, anon cannot execute ' || split_part(v_sig, '(', 1),
      has_function_privilege('authenticated', v_sig, 'execute') and not has_function_privilege('anon', v_sig, 'execute'));
  end loop;
  foreach v_sig in array array[
    'public._record_transaction_referrer(uuid,uuid,uuid,uuid,text,text,text)', 'public._apply_customer_referrer(uuid,uuid,uuid)',
    'public._validate_referrer(uuid,uuid,uuid,uuid,text)', 'public._maybe_award_customer_referral(uuid)',
    'public._carry_over_lead_referral(uuid,uuid,uuid,text,uuid)'] loop
    perform pg_temp.chk('AC-9 internal helper not callable by authenticated/anon: ' || split_part(v_sig, '(', 1),
      not has_function_privilege('authenticated', v_sig, 'execute') and not has_function_privilege('anon', v_sig, 'execute'));
  end loop;
  perform pg_temp.chk('billing RPCs unchanged (md5 = 2026-11-26 pins)',
    md5(pg_get_functiondef('public.create_sale(uuid,uuid,jsonb,uuid,integer,uuid,numeric)'::regprocedure)) = '8cec65d63909a6acdd31367dd01a789d'
    and md5(pg_get_functiondef('public.create_complaint_ticket(uuid,uuid,uuid,uuid,uuid,uuid,text,text,priority_level,ticket_channel,appointment_mode,boolean,date,uuid,uuid,text,uuid,jsonb,uuid)'::regprocedure)) = '47cabf68e71d9adccc835770b4b79985'
    and md5(pg_get_functiondef('public.sell_amc_plan(uuid,uuid,uuid,uuid,date,integer,uuid,boolean)'::regprocedure)) = 'c8ef1b8da309fc0a7cca1e976552159a'
    and md5(pg_get_functiondef('public.create_customer_with_details(uuid,text,text,jsonb,jsonb,uuid)'::regprocedure)) = '08902395d624cdffd8aa7c2f7e5eb3e2');
end $t$;

do $r$
declare v_pass int; v_fail int; v_lines text;
begin
  select count(*) filter (where line like 'PASS%'), count(*) filter (where line like 'FAIL%'), string_agg(line, E'\n' order by n)
    into v_pass, v_fail, v_lines from pg_temp.res;
  raise exception E'RESULTS (% pass / % fail) -- rolled back, nothing persists\n%', v_pass, v_fail, v_lines;
end $r$;
