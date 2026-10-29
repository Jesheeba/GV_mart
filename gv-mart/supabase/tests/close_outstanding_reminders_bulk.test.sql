-- DB test for 20261116100000_close_outstanding_reminders_bulk.sql.
-- NOT RUN standalone (written for review) -- run only through the approved
-- rehearsal wrapper. Throwaway __TEST_ organisation only.

create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_name text default null) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, coalesce(p_name, '__TEST_ ' || p_role), p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id, full_name = excluded.full_name;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid;
  v_master uuid; v_tp uuid;
  v_cust_paid uuid; v_cust_still_owes uuid; v_cust_other_org uuid;
  v_inv1 uuid; v_inv2 uuid;
  v_rem1 public.customer_outstanding_reminders;
  v_rem2 public.customer_outstanding_reminders;
  v_closed int;
begin
  insert into organizations (name) values ('__TEST_closebulk') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org, '__TEST_ Mira Master');
  v_tp := pg_temp.mkuser('technician', v_org, '__TEST_ Tara Tech');
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true);

  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Fully Paid Now', '9400000221') returning id into v_cust_paid;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Still Owes', '9400000222') returning id into v_cust_still_owes;

  -- This customer's invoice is now fully paid -- its open reminder must auto-close on the bulk sweep.
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust_paid, 'product', 1000, 0, 1000, 1000, 'paid') returning id into v_inv1;
  -- This customer still owes money -- its open reminder must NOT close.
  insert into invoices (org_id, customer_id, type, subtotal, gst, total, amount_paid, payment_status)
    values (v_org, v_cust_still_owes, 'product', 1000, 0, 1000, 200, 'partial') returning id into v_inv2;

  perform pg_temp.as_user(v_master);
  select * into v_rem1 from public.create_customer_outstanding_reminder(v_cust_paid, now() + interval '1 day', 'test', v_inv1, 1000);
  select * into v_rem2 from public.create_customer_outstanding_reminder(v_cust_still_owes, now() + interval '1 day', 'test', v_inv2, 800);

  -- 1. The bulk sweep closes the fully-paid customer's reminder and leaves the other open.
  select public.close_outstanding_reminders_if_zero_bulk() into v_closed;
  perform pg_temp.chk('bulk sweep closes exactly 1 reminder (the fully-paid customer)', v_closed = 1, v_closed::text);
  perform pg_temp.chk('the fully-paid customer''s reminder is now done, source=system, with a close_reason',
    (select status = 'done' and source = 'system' and close_reason = 'outstanding reached zero' from public.customer_outstanding_reminders where id = v_rem1.id));
  perform pg_temp.chk('the still-owing customer''s reminder is untouched (still open)',
    (select status = 'open' from public.customer_outstanding_reminders where id = v_rem2.id));

  -- 2. Running it again is a safe no-op (nothing left open for the paid customer).
  select public.close_outstanding_reminders_if_zero_bulk() into v_closed;
  perform pg_temp.chk('re-running the sweep closes 0 (already closed, idempotent)', v_closed = 0, v_closed::text);

  -- 3. Role gating: technician and anon are both refused.
  perform pg_temp.as_user(v_tp);
  begin
    perform public.close_outstanding_reminders_if_zero_bulk();
    perform pg_temp.chk('technician is refused (expected an exception, got none)', false);
  exception when others then
    perform pg_temp.chk('technician is refused with the master-only error', sqlerrm = 'close_outstanding_reminders_if_zero_bulk: master only', sqlerrm);
  end;

  perform pg_temp.as_anon();
  begin
    perform public.close_outstanding_reminders_if_zero_bulk();
    perform pg_temp.chk('anon is refused (expected an exception, got none)', false);
  exception when others then
    perform pg_temp.chk('anon is refused (permission denied or master-only)', true, sqlerrm);
  end;

  perform pg_temp.as_pg();

  -- cleanup within the same throwaway org -- not strictly required (whole org is rolled back
  -- by the rehearsal wrapper's final RAISE) but keeps this file honest if ever run alone.
  delete from public.customer_outstanding_links where customer_id in (v_cust_paid, v_cust_still_owes);
  delete from public.customer_outstanding_reminders where customer_id in (v_cust_paid, v_cust_still_owes);

  -- Unconditional final raise (this project's hard rule: a test that can return without raising
  -- can be concatenated in front of an unapproved migration and committed live by accident -- see
  -- the 2026-10-13 "migration + test concat accident" postmortem). Never a plain RAISE NOTICE.
  raise exception E'RESULTS:%', (select string_agg(line, E'\n' order by n) from pg_temp.res);
end;
$t$;
