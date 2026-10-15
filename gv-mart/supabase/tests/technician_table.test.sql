-- DB tests for 20261030100000_technician_table. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
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
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
-- a completed ticket with one finished visit by p_tech and an invoice of p_total, finished on p_day
create function pg_temp.job(p_org uuid, p_cust uuid, p_tech uuid, p_total numeric, p_day date, p_type text default 'spare') returns uuid language plpgsql as $f$
declare t uuid; v uuid; i uuid;
begin
  insert into public.invoices (org_id, customer_id, type, subtotal, total, payment_status) values (p_org, p_cust, p_type::public.invoice_type, p_total, p_total, 'due') returning id into i;
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint, invoice_id) values (p_org, p_cust, 'paid', '__TEST_ job', i) returning id into t;
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (p_org, t, p_tech, (p_day::timestamp + interval '10 hours') at time zone 'Asia/Kolkata', (p_day::timestamp + interval '11 hours') at time zone 'Asia/Kolkata') returning id into v;
  update public.service_tickets set status = 'completed' where id = t;
  return v;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_master2 uuid;
  v_p1 uuid; v_p2 uuid; v_t1 uuid; v_t2 uuid; v_c uuid; v_ctest uuid; v_cref uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_mon date; v_from date; v_to date; v_vis uuid; v_inv uuid;
  r record; s text; n int;
begin
  -- the Monday of the week before last: a fixed 12-day window Monday..Saturday of the following week, all in the past
  v_mon := v_today - ((extract(isodow from v_today)::int - 1) + 14);
  v_from := v_mon;                 -- Monday
  v_to := v_mon + 12;              -- Saturday of the next week (Mon..Sat, Sun, Mon..Sat = 12 working days)

  insert into organizations (name) values ('__TEST_techtable') returning id into v_org;
  insert into organizations (name) values ('__TEST_techtable_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_p1 := pg_temp.mkuser('technician', v_org);
  v_p2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p1, true) returning id into v_t1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p2, true) returning id into v_t2;
  -- technicians created long ago, so every day in the window counts
  update technicians set created_at = now() - interval '200 days' where id in (v_t1, v_t2);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c', '9400000096') returning id into v_c;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000097', true) returning id into v_ctest;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ referred', '9400000098') returning id into v_cref;

  -- ---------- structure and grants ----------
  perform pg_temp.chk('org_holidays exists with RLS; invoices.referred_by_technician_id exists, nullable',
    exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'org_holidays' and c.relrowsecurity)
    and (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'referred_by_technician_id') = 'YES');
  perform pg_temp.chk('report_technician_table: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.report_technician_table(date,date)', 'execute')
    and not has_function_privilege('anon', 'public.report_technician_table(date,date)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('report_technician_table', '_trg_invoice_stamp_referral'))
    and not has_function_privilege('authenticated', 'public._trg_invoice_stamp_referral()', 'execute'));
  perform pg_temp.chk('no Google-review column in the result',
    not exists (select 1 from pg_proc p, unnest(p.proargnames) a where p.proname = 'report_technician_table' and p.pronamespace = 'public'::regnamespace
                 and (a ilike '%google%' or a ilike '%review%')));

  -- ---------- attendance: present, leave, holiday, absent ----------
  -- window = 12 working days (Mon..Sat twice). t1: present 5 days, leave 2 days (one of them also present), 1 holiday
  insert into attendance (org_id, technician_id, date, check_in_at)
    select v_org, v_t1, v_from + k, now() from unnest(array[0, 1, 2, 3, 4]) k;
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t1, v_from + 7, 'leave'), (v_org, v_t1, v_from + 8, 'leave');
  insert into attendance (org_id, technician_id, date, check_in_at) values (v_org, v_t1, v_from + 8, now());   -- present AND leave: counted once
  insert into org_holidays (org_id, holiday_date, name) values (v_org, v_from + 9, '__TEST_ holiday');
  -- a Sunday attendance must not change the working-day arithmetic
  insert into attendance (org_id, technician_id, date, check_in_at) values (v_org, v_t1, v_from + 6, now());

  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  -- working days: 12 (Mon..Sat x2) minus 1 holiday = 11; covered = present(0..4 and 8) + leave(7, 8) = {0,1,2,3,4,7,8} = 7 days
  perform pg_temp.chk('working days = Monday to Saturday minus holidays', r.working_days = 11 and r.holidays = 1, r.working_days::text || '/' || r.holidays::text);
  perform pg_temp.chk('present and leave are counted on working days; a Sunday check-in is ignored',
    r.present_days = 6 and r.leave_days = 2, r.present_days::text || '/' || r.leave_days::text);
  perform pg_temp.chk('absent = working days - days present or on leave (a day both present and on leave counts once)',
    r.absent_days = 11 - 7, r.absent_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician with no attendance is absent on every working day', r.absent_days = 11 and r.present_days = 0 and r.leave_days = 0, r.absent_days::text);

  -- future days are not counted as absent; a technician created mid-window counts from that day
  update technicians set created_at = ((v_from + 3)::timestamp at time zone 'Asia/Kolkata') where id = v_t2;
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('days before the technician record existed are not counted', r.working_days = 11 - 3, r.working_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today, v_today + 30) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('future dates are never counted: at most today',
    r.working_days <= 1, r.working_days::text);

  -- ---------- revenue and jobs ----------
  v_vis := pg_temp.job(v_org, v_c, v_t1, 1000, v_from + 1);
  perform pg_temp.job(v_org, v_c, v_t1, 2500, v_from + 2);
  perform pg_temp.job(v_org, v_ctest, v_t1, 9999, v_from + 2);                 -- flagged test customer: left out
  perform pg_temp.job(v_org, v_c, v_t2, 400, v_from + 3);
  perform pg_temp.job(v_org, v_c, v_t1, 777, v_from - 20);                      -- outside the period
  -- a completed job with no invoice counts as a job, adds no revenue
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ no invoice')
    returning id into v_inv;
  insert into service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_inv, v_t1, ((v_from + 4)::timestamp + interval '9 hours') at time zone 'Asia/Kolkata', ((v_from + 4)::timestamp + interval '10 hours') at time zone 'Asia/Kolkata');
  update service_tickets set status = 'completed' where id = v_inv;
  insert into ratings (org_id, visit_id, stars) values (v_org, v_vis, 4);

  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('revenue = invoice totals of completed jobs in the period (test customers and other periods left out)',
    r.revenue = 3500 and r.jobs_completed = 3 and r.jobs_invoiced = 2, r.revenue::text || '/' || r.jobs_completed::text || '/' || r.jobs_invoiced::text);
  perform pg_temp.chk('average call value = revenue / invoiced jobs', r.avg_call_value = 1750.00, coalesce(r.avg_call_value::text, 'null'));
  perform pg_temp.chk('customer-app rating average is shown (not a Google review)', r.avg_rating = 4.00 and r.rating_count = 1, coalesce(r.avg_rating::text, 'null'));
  -- an open (not completed) job adds nothing
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_c, 'spare', 50, 50, 'due') returning id into v_inv;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, invoice_id) values (v_org, v_c, 'paid', '__TEST_ open', v_inv);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a ticket that is not completed adds no revenue', r.revenue = 3500);

  -- ---------- referral revenue: forward-only stamp ----------
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_cref, '__TEST_ referral', 'referral', 'won', v_t1);
  v_inv := null;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 8000, 8000, 'paid') returning id into v_inv;
  perform pg_temp.chk('an invoice for a customer with a technician-referral lead is stamped at insert',
    (select referred_by_technician_id from invoices where id = v_inv) = v_t1);
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'amc', 3000, 3000, 'paid');
  perform pg_temp.job(v_org, v_cref, v_t2, 600, v_today - 1, 'spare');
  perform pg_temp.chk('an invoice for a customer with no referral lead is not stamped',
    (select referred_by_technician_id is null from invoices where customer_id = v_c and org_id = v_org limit 1));
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 2, v_today + 1) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('referral revenue is split for the referrer: sales 8000, AMC 3000, service 600 (the stamped service invoice)',
    r.referral_sales = 8000 and r.referral_amc = 3000 and r.referral_service = 600 and r.referral_total = 11600,
    r.referral_sales::text || '/' || r.referral_amc::text || '/' || r.referral_service::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 2, v_today + 1) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('the technician who did the referred service job gets the job revenue, not the referral revenue',
    r.referral_total = 0 and r.revenue >= 600, r.referral_total::text || '/' || r.revenue::text);

  -- 30-day window and lost leads
  update leads set created_at = now() - interval '45 days' where org_id = v_org and customer_id = v_cref;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 5, 5, 'paid') returning id into v_inv;
  perform pg_temp.chk('a referral lead older than 30 days does not stamp', (select referred_by_technician_id is null from invoices where id = v_inv));
  update leads set created_at = now() - interval '2 days', status = 'lost' where org_id = v_org and customer_id = v_cref;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 6, 6, 'paid') returning id into v_inv;
  perform pg_temp.chk('a lost referral lead does not stamp', (select referred_by_technician_id is null from invoices where id = v_inv));

  -- forward-only: a referral lead created AFTER an invoice never stamps that invoice
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_c, 'product', 11, 11, 'paid') returning id into v_inv;
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c, '__TEST_ late referral', 'referral', 'won', v_t2);
  update invoices set total = total where id = v_inv;
  perform pg_temp.chk('nothing back-fills: the earlier invoice stays unstamped after the referral lead appears and the invoice is updated',
    (select referred_by_technician_id is null from invoices where id = v_inv));

  -- ---------- roles and org scope ----------
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('sales_admin cannot read the technician table', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('a customer-role user cannot read it', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('anon cannot call it', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master2);
  select count(*) into n from report_technician_table(v_from, v_to) where technician_id in (v_t1, v_t2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none of these technicians', n = 0, n::text);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_to, v_from));
  perform pg_temp.chk('a reversed range is refused', s like '%invalid date range%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_today - 400, v_today));
  perform pg_temp.chk('a range over 366 days is refused', s like '%limited to 366%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- holidays: master writes, staff read ----------
  perform pg_temp.as_user(v_master);
  insert into org_holidays (org_id, holiday_date, name) values (v_org, v_from + 10, '__TEST_ second holiday');
  perform pg_temp.as_user(v_ops);
  select count(*) into n from org_holidays;
  s := pg_temp.raises(format($q$insert into org_holidays (org_id, holiday_date, name) values (%L, %L, 'x')$q$, v_org, v_from + 11));
  perform pg_temp.as_pg();
  perform pg_temp.chk('operations can read holidays (2) but not write them', n = 2 and s is not null, n::text || ' / ' || coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into org_holidays (org_id, holiday_date, name) values (%L, %L, 'dup')$q$, v_org, v_from + 10));
  perform pg_temp.chk('one holiday per date', s like '%duplicate key%', coalesce(s, 'accepted'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
