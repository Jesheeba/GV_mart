-- Rolled-back DB tests for migration 20261009120000 (reports SQL aggregation 3): report_performance,
-- report_ops_resolution, report_feedback, report_expenses_salary_by_staff, report_expenses_year_over_year.
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
  o uuid; m uuid; sa uuid; techuser uuid; custuser uuid; t1 uuid; t2 uuid; t3 uuid; c uuid; r jsonb; r2 jsonb;
  tk uuid; v1 uuid; v2 uuid; v3 uuid; v4 uuid; vout uuid;
  today date := (now() at time zone 'Asia/Kolkata')::date; cy int := extract(year from (now() at time zone 'Asia/Kolkata'))::int; doy int := extract(doy from (now() at time zone 'Asia/Kolkata'))::int;
begin
  o := pg_temp.mkorg('perf');
  if (select name from organizations where id = o) not like '\_\_TEST\_%' then raise exception 'refusing to run outside a __TEST_ org'; end if;
  m := pg_temp.mkuser('master', o); sa := pg_temp.mkuser('sales_admin', o); techuser := pg_temp.mkuser('technician', o); custuser := pg_temp.mkuser('customer', o);
  t1 := pg_temp.mktech(o); t2 := pg_temp.mktech(o); t3 := pg_temp.mktech(o);
  update public.profiles set full_name = 'Tech One' where id = (select profile_id from public.technicians where id = t1);
  update public.profiles set full_name = 'Tech Two' where id = (select profile_id from public.technicians where id = t2);
  update public.profiles set full_name = 'Lead Only' where id = (select profile_id from public.technicians where id = t3);
  c := pg_temp.mkcust(o, 'Perf Customer');
  tk := pg_temp.mkticket(o, c, 'paid', null);

  -- ===== performance fixture (October 2026) =====
  -- t1: V1 charge 500, 45 min, no revisit ; V2 charge 300, 75 min, needs revisit ; V3 charge 0, never closed (no timer_end)
  --     jobs 3, revenue 800, on-time 2/3 = 66.7, average completion (45 + 75) / 2 = 60, rating (4 + 5) / 2 = 4.5 over 2
  -- t2: V4 charge 200, 30 min, no revisit -> jobs 1, revenue 200, on-time 100.0, completion 30, rating 3.0 over 1
  v1 := pg_temp.mkvisit(o, tk, t1, timestamptz '2026-10-10 10:00:00+05:30', 500);
  v2 := pg_temp.mkvisit(o, tk, t1, timestamptz '2026-10-12 11:00:00+05:30', 300);
  v3 := pg_temp.mkvisit(o, tk, t1, timestamptz '2026-10-13 11:00:00+05:30', 0);
  v4 := pg_temp.mkvisit(o, tk, t2, timestamptz '2026-10-11 10:00:00+05:30', 200);
  vout := pg_temp.mkvisit(o, tk, t1, timestamptz '2026-11-01 00:30:00+05:30', 999);   -- 00:30 IST Nov 1: outside October
  update public.service_visits set timer_end = timer_start + interval '45 minutes' where id = v1;
  update public.service_visits set timer_end = timer_start + interval '75 minutes', needs_revisit = true where id = v2;
  update public.service_visits set timer_end = timer_start + interval '30 minutes' where id = v4;
  -- ratings attach through the VISIT's date (rating created later, in November, still counts for October)
  insert into public.ratings (org_id, visit_id, stars, created_at) values (o, v1, 4, timestamptz '2026-10-10 12:00:00+05:30'), (o, v2, 5, timestamptz '2026-11-05 12:00:00+05:30'), (o, v4, 3, timestamptz '2026-10-11 12:00:00+05:30');
  -- leads: owner t1 4 created in Oct (2 won) = 50.0 ; owner t3 3 (1 won) = 33.3 ; no owner ignored ; one created Nov 1 00:30 IST ignored
  insert into public.leads (org_id, name, owner_id, status, created_at) values
    (o, 'l1', t1, 'won', timestamptz '2026-10-02 12:00:00+05:30'), (o, 'l2', t1, 'won', timestamptz '2026-10-03 12:00:00+05:30'), (o, 'l3', t1, 'new', timestamptz '2026-10-04 12:00:00+05:30'), (o, 'l4', t1, 'lost', timestamptz '2026-10-05 12:00:00+05:30'),
    (o, 'l5', t3, 'won', timestamptz '2026-10-06 12:00:00+05:30'), (o, 'l6', t3, 'new', timestamptz '2026-10-07 12:00:00+05:30'), (o, 'l7', t3, 'contacted', timestamptz '2026-10-08 12:00:00+05:30'),
    (o, 'l8', null, 'won', timestamptz '2026-10-09 12:00:00+05:30'), (o, 'l9', t1, 'won', timestamptz '2026-11-01 00:30:00+05:30');
  -- attendance: t1 8h + 8h (+ a day with no check-out, ignored) = 16h -> 3 / 16 = 0.19 ; t2 2h -> 1 / 2 = 0.50 ; t3 10h -> 0 / 10 = 0.00
  insert into public.attendance (org_id, technician_id, date, check_in_at, check_out_at) values
    (o, t1, date '2026-10-10', timestamptz '2026-10-10 09:00:00+05:30', timestamptz '2026-10-10 17:00:00+05:30'),
    (o, t1, date '2026-10-12', timestamptz '2026-10-12 09:00:00+05:30', timestamptz '2026-10-12 17:00:00+05:30'),
    (o, t1, date '2026-10-13', timestamptz '2026-10-13 09:00:00+05:30', null),
    (o, t2, date '2026-10-11', timestamptz '2026-10-11 09:00:00+05:30', timestamptz '2026-10-11 11:00:00+05:30'),
    (o, t3, date '2026-10-14', timestamptz '2026-10-14 08:00:00+05:30', timestamptz '2026-10-14 18:00:00+05:30');
  -- installs (to technicians that already have a row): t1 2, t2 1, t3 5 ; outside window 9
  declare brand uuid; model uuid; prod uuid;
  begin
    insert into public.brands (org_id, name, category) values (o, 'b', 'ro') returning id into brand;
    insert into public.models (org_id, brand_id, name) values (o, brand, 'm') returning id into model;
    insert into public.products (org_id, brand_id, model_id, name, category, price) values (o, brand, model, 'P', 'ro', 100) returning id into prod;
    insert into public.installations_logged (org_id, visit_id, technician_id, product_id, qty, created_at) values
      (o, v1, t1, prod, 2, timestamptz '2026-10-05 12:00:00+05:30'), (o, v1, t2, prod, 1, timestamptz '2026-10-05 12:00:00+05:30'), (o, v1, t3, prod, 5, timestamptz '2026-10-05 12:00:00+05:30'), (o, v1, t1, prod, 9, timestamptz '2026-11-01 00:30:00+05:30');
  end;

  perform pg_temp.as_user(m);
  r := public.report_performance(date '2026-10-01', date '2026-10-31');
  perform pg_temp.as_pg();
  perform pg_temp.chk('performance_matches_legacy_fields: 3 rows ordered by revenue (Tech One 800, Tech Two 200, Lead Only 0)', jsonb_array_length(r) = 3 and r->0->>'id' = t1::text and r->1->>'id' = t2::text and r->2->>'id' = t3::text, (select string_agg(x->>'name', ',') from jsonb_array_elements(r) x));
  perform pg_temp.chk('performance_matches_legacy_fields: Tech One', r->0->>'name' = 'Tech One' and r->0->>'role' = 'technician' and pg_temp.n(r,'{0,jobs_done}')=3 and pg_temp.n(r,'{0,revenue}')=800 and pg_temp.n(r,'{0,on_time_percent}')=66.7
    and pg_temp.n(r,'{0,avg_rating}')=4.5 and pg_temp.n(r,'{0,review_count}')=2 and pg_temp.n(r,'{0,conversion_percent}')=50.0 and pg_temp.n(r,'{0,avg_completion_minutes}')=60
    and pg_temp.n(r,'{0,productivity_jobs_per_hour}')=0.19 and pg_temp.n(r,'{0,installations}')=2, (r->0)::text);
  perform pg_temp.chk('performance_matches_legacy_fields: Tech Two', r->1->>'name' = 'Tech Two' and pg_temp.n(r,'{1,jobs_done}')=1 and pg_temp.n(r,'{1,revenue}')=200 and pg_temp.n(r,'{1,on_time_percent}')=100.0 and pg_temp.n(r,'{1,avg_rating}')=3.0
    and pg_temp.n(r,'{1,review_count}')=1 and (r->1->>'conversion_percent') is null and pg_temp.n(r,'{1,avg_completion_minutes}')=30 and pg_temp.n(r,'{1,productivity_jobs_per_hour}')=0.5 and pg_temp.n(r,'{1,installations}')=1, (r->1)::text);
  perform pg_temp.chk('performance: a lead owner with no visits shows the real name, not a dash, with nulls for visit metrics',
    r->2->>'name' = 'Lead Only' and pg_temp.n(r,'{2,jobs_done}')=0 and pg_temp.n(r,'{2,revenue}')=0 and (r->2->>'on_time_percent') is null and (r->2->>'avg_rating') is null and pg_temp.n(r,'{2,review_count}')=0
    and pg_temp.n(r,'{2,conversion_percent}')=33.3 and (r->2->>'avg_completion_minutes') is null and pg_temp.n(r,'{2,productivity_jobs_per_hour}')=0 and pg_temp.n(r,'{2,installations}')=5, (r->2)::text);
  perform pg_temp.chk('performance: 00:30 IST Nov 1 visit / lead / install are outside October (revenue 800 not 1,799)', pg_temp.n(r,'{0,revenue}')=800 and pg_temp.n(r,'{0,installations}')=2);

  -- ===== ops_resolution_24h =====
  declare ta uuid; tb uuid; tc uuid; td uuid; te uuid; base timestamptz := timestamptz '2026-10-10 10:00:00+05:30';
  begin
    set local session_replication_role = replica;   -- test-only: insert explicit created_at / updated_at without the updated_at trigger
    insert into public.service_tickets (org_id, customer_id, type, status, created_at, updated_at) values
      (o, c, 'paid', 'completed', base, base + interval '23 hours 59 minutes'),
      (o, c, 'paid', 'completed', base, base + interval '24 hours'),
      (o, c, 'paid', 'completed', base, base + interval '24 hours 1 minute'),
      (o, c, 'paid', 'open', base, base + interval '1 hour'),
      (o, c, 'paid', 'completed', timestamptz '2026-11-01 00:30:00+05:30', timestamptz '2026-11-01 01:30:00+05:30');
    set local session_replication_role = origin;
    perform pg_temp.as_user(m);
    r := public.report_ops_resolution(date '2026-10-01', date '2026-10-31');
    r2 := public.report_ops_resolution(date '2026-03-01', date '2026-03-31');
    perform pg_temp.as_pg();
    -- the setup ticket above (status open) is not completed; 3 completed in Oct: 23:59 and exactly 24:00 are within, 24:01 is not
    perform pg_temp.chk('ops_resolution_24h: 2 of 3 completed within 24h (exactly 24:00 counts, 24:01 does not) = 66.7; open and November tickets excluded',
      pg_temp.n(r,'{resolved_within_24h}')=2 and pg_temp.n(r,'{total_completed}')=3 and pg_temp.n(r,'{percent}')=66.7, r::text);
    perform pg_temp.chk('ops_resolution_24h: nothing completed -> percent null', pg_temp.n(r2,'{total_completed}')=0 and (r2->>'percent') is null and pg_temp.n(r2,'{resolved_within_24h}')=0, r2::text);
  end;

  -- ===== feedback_ist_day_trend =====
  declare fv uuid[]; rid uuid[] := array[]::uuid[]; i int; st numeric[] := array[5, 3, 4, 5, 1, 4.5];
    at_ts timestamptz[] := array[timestamptz '2026-10-10 02:00:00+05:30', timestamptz '2026-10-10 23:30:00+05:30', timestamptz '2026-10-11 12:00:00+05:30', timestamptz '2026-10-31 23:50:00+05:30', timestamptz '2026-11-01 00:30:00+05:30', timestamptz '2026-10-12 12:00:00+05:30'];
    f_cust uuid; f_tk uuid; f_v uuid; rr uuid;
    of uuid := pg_temp.mkorg('feedback'); mf uuid := pg_temp.mkuser('master', of); tf uuid := pg_temp.mktech(of);
  begin
    update public.profiles set full_name = 'Tech One' where id = (select profile_id from public.technicians where id = tf);
    f_cust := pg_temp.mkcust(of, 'Feedback Customer');
    f_tk := pg_temp.mkticket(of, f_cust, 'paid', null);
    for i in 1..6 loop
      f_v := pg_temp.mkvisit(of, f_tk, tf, timestamptz '2026-12-01 10:00:00+05:30', 0);
      insert into public.ratings (org_id, visit_id, stars, review, created_at) values (of, f_v, st[i], 'review ' || i, at_ts[i]) returning id into rr;
      rid := rid || rr;
    end loop;
    -- a low_rating notification for the 3-star rating (#2) in the exact body format submit_rating() writes; none for the 4-star one (#3)
    insert into public.notifications (org_id, role, type, title, body, ref_id) values (of, 'operation_admin', 'low_rating', 'Low rating', 'A 3-star rating was recorded. Reason: Late arrival', rid[2]);
    perform pg_temp.as_user(mf);
    r := public.report_feedback(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    -- in October: 5, 3, 4, 5, 4.5 -> rounded buckets 5,3,4,5,5 => 1:0 2:0 3:1 4:1 5:3 ; average 21.5 / 5 = 4.30 (the 1-star at 00:30 IST Nov 1 is excluded)
    perform pg_temp.chk('feedback: stars distribution (4.5 rounds to 5) and average 4.30', r->'stars_distribution' = jsonb_build_array(jsonb_build_object('stars',1,'count',0), jsonb_build_object('stars',2,'count',0), jsonb_build_object('stars',3,'count',1), jsonb_build_object('stars',4,'count',1), jsonb_build_object('stars',5,'count',3))
      and pg_temp.n(r,'{average_rating}')=4.30, (r->'stars_distribution')::text || ' avg ' || (r->>'average_rating'));
    -- IST days: the 02:00 IST rating (= Oct 9 20:30 UTC) belongs to Oct 10 with the 23:30 IST one: (5 + 3) / 2 = 4.00 ; Oct 11 4.00 ; Oct 12 4.50 ; Oct 31 5.00
    perform pg_temp.chk('feedback_ist_day_trend: 02:00 IST rating groups with its IST day (Oct 10), not the UTC date (Oct 9)',
      r->'trend' = jsonb_build_array(jsonb_build_object('date','2026-10-10','average_rating',4.00), jsonb_build_object('date','2026-10-11','average_rating',4.00), jsonb_build_object('date','2026-10-12','average_rating',4.50), jsonb_build_object('date','2026-10-31','average_rating',5.00)), (r->'trend')::text);
    perform pg_temp.chk('feedback: low ratings are stars < 4.5 (3 and 4; the 4.5 is not low), oldest first, with reason / customer / technician',
      jsonb_array_length(r->'low_rating_entries') = 2 and pg_temp.n(r,'{low_rating_entries,0,stars}')=3 and r->'low_rating_entries'->0->>'reason' = 'Late arrival' and r->'low_rating_entries'->0->>'customer_name' = 'Feedback Customer'
      and r->'low_rating_entries'->0->>'technician_name' = 'Tech One' and r->'low_rating_entries'->0->>'review' = 'review 2' and pg_temp.n(r,'{low_rating_entries,1,stars}')=4 and (r->'low_rating_entries'->1->>'reason') is null, (r->'low_rating_entries')::text);
    perform pg_temp.as_user(mf);
    r2 := public.report_feedback(date '2026-03-01', date '2026-03-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('feedback: no ratings -> average null, empty trend and entries, 5 zero buckets', (r2->>'average_rating') is null and r2->'trend' = '[]'::jsonb and r2->'low_rating_entries' = '[]'::jsonb and jsonb_array_length(r2->'stars_distribution') = 5);
  end;

  -- ===== Accounts aggregates: salary by staff + year over year =====
  declare s1 uuid := pg_temp.mkuser('operation_admin', o); s2 uuid := pg_temp.mkuser('sales_admin', o);
  begin
    update public.profiles set full_name = 'Staff A' where id = s1;
    update public.profiles set full_name = 'Staff B' where id = s2;
    insert into public.expenses (org_id, category, amount, date, staff_id) values
      (o, 'salary', 20000, date '2026-10-31', s1), (o, 'salary', 5000, date '2026-10-15', s1), (o, 'salary', 12000, date '2026-10-01', s2),
      (o, 'salary', 999, date '2026-11-01', s2),            -- outside the window
      (o, 'salary', 777, date '2026-10-10', null),          -- no staff member: not in the drill-down
      (o, 'rent', 10000, date '2026-10-01', s1);            -- not a salary
    perform pg_temp.as_user(m);
    r := public.report_expenses_salary_by_staff(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('salary_by_staff: Staff A 25,000 then Staff B 12,000 (only salary with a staff id, in the window)', jsonb_array_length(r) = 2 and r->0->>'staff_id' = s1::text and r->0->>'staff_name' = 'Staff A' and pg_temp.n(r,'{0,total}')=25000 and r->1->>'staff_id' = s2::text and pg_temp.n(r,'{1,total}')=12000, r::text);
    perform pg_temp.as_user(sa);
    r := public.report_expenses_salary_by_staff(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('non_master_gets_zero_expenses: sales_admin gets [] from salary_by_staff', r = '[]'::jsonb, r::text);

  end;

  -- year over year, relative to today in IST (cy / doy), in its own organisation so the totals are exact
  declare oy uuid := pg_temp.mkorg('yoy'); my uuid := pg_temp.mkuser('master', oy); say uuid := pg_temp.mkuser('sales_admin', oy);
  begin
    insert into public.expenses (org_id, category, amount, date) values
      (oy, 'salary', 100, make_date(cy, 1, 1)), (oy, 'rent', 300, make_date(cy, 1, 2)), (oy, 'salary', 40, make_date(cy, 12, 31)),
      (oy, 'rent', 1000, make_date(cy - 1, 1, 1)), (oy, 'rent', 500, make_date(cy - 1, 12, 31)),
      (oy, 'petrol', 7, make_date(cy - 3, 6, 1)),
      (oy, 'petrol', 9999, make_date(cy - 4, 6, 1));      -- older than yearsBack: excluded
    perform pg_temp.as_user(my);
    r := public.report_expenses_year_over_year(3);
    perform pg_temp.as_pg();
    perform pg_temp.chk('year_over_year: 4 rows, current IST year first, going back 3', jsonb_array_length(r) = 4 and pg_temp.n(r,'{0,year}')=cy and pg_temp.n(r,'{3,year}')=cy-3, (select string_agg(x->>'year', ',') from jsonb_array_elements(r) x));
    -- this year: full 100 + 300 + 40 = 440 ; year-to-date 100 + 300 (+ 40 only once today has reached Dec 31)
    perform pg_temp.chk('year_over_year: this year full 440, year-to-date cut at today''s day-of-year, categories by amount desc',
      pg_temp.n(r,'{0,full_year_total}')=440 and pg_temp.n(r,'{0,ytd_comparable_total}')=400 + case when doy >= extract(doy from make_date(cy, 12, 31)) then 40 else 0 end
      and r->0->'by_category' = jsonb_build_array(jsonb_build_object('category','rent','amount',300), jsonb_build_object('category','salary','amount',140)), (r->0)::text);
    perform pg_temp.chk('year_over_year: previous year full 1,500 and year-to-date 1,000 (the Dec 31 500 counts only once today passes that day)',
      pg_temp.n(r,'{1,full_year_total}')=1500 and pg_temp.n(r,'{1,ytd_comparable_total}')=1000 + case when doy >= extract(doy from make_date(cy - 1, 12, 31)) then 500 else 0 end, (r->1)::text);
    perform pg_temp.chk('year_over_year: empty year has zeros and no categories; the oldest year holds only its own expense (older year excluded)', pg_temp.n(r,'{2,full_year_total}')=0 and r->2->'by_category' = '[]'::jsonb and pg_temp.n(r,'{3,full_year_total}')=7
      and r->3->'by_category' = jsonb_build_array(jsonb_build_object('category','petrol','amount',7)), (r->2)::text || (r->3)::text);
    perform pg_temp.as_user(say);
    r := public.report_expenses_year_over_year(3);
    perform pg_temp.as_pg();
    perform pg_temp.chk('non_master_gets_zero_expenses: sales_admin gets four zero years from year_over_year', jsonb_array_length(r) = 4 and (select bool_and((x->>'full_year_total')::numeric = 0 and x->'by_category' = '[]'::jsonb) from jsonb_array_elements(r) x), r::text);
  end;

  -- ===== gates: every new function rejects technician and customer; anon denied; other org sees zeros =====
  declare fn text; who text; bad text := ''; e text;
  begin
    foreach fn in array array['public.report_performance(date ''2026-10-01'', date ''2026-10-31'')', 'public.report_ops_resolution(date ''2026-10-01'', date ''2026-10-31'')', 'public.report_feedback(date ''2026-10-01'', date ''2026-10-31'')',
                              'public.report_expenses_salary_by_staff(date ''2026-10-01'', date ''2026-10-31'')', 'public.report_expenses_year_over_year(3)'] loop
      foreach who in array array[techuser::text, custuser::text] loop
        begin perform pg_temp.as_user(who::uuid); execute 'select ' || fn; bad := bad || fn || ' ';
        exception when others then if sqlerrm not like 'not permitted%' then bad := bad || '[' || sqlerrm || '] '; end if; end;
        perform pg_temp.as_pg();
      end loop;
      begin execute 'set local role anon'; execute 'select ' || fn; bad := bad || 'ANON-OK:' || fn || ' ';
      exception when others then if sqlerrm not like 'permission denied%' then bad := bad || '[' || sqlerrm || '] '; end if; end;
      perform pg_temp.as_pg();
    end loop;
    perform pg_temp.chk('role gate: technician/customer raise "not permitted" and anon gets "permission denied" on all 5 new functions', bad = '', bad);
  end;
  declare o2 uuid := pg_temp.mkorg('perf_other'); m2 uuid := pg_temp.mkuser('master', o2);
  begin
    perform pg_temp.as_user(m2);
    r := public.report_performance(date '2026-10-01', date '2026-10-31');
    r2 := public.report_feedback(date '2026-10-01', date '2026-10-31');
    perform pg_temp.as_pg();
    perform pg_temp.chk('cross-org: another organisation sees no performance rows and no ratings', r = '[]'::jsonb and r2->'low_rating_entries' = '[]'::jsonb and (r2->>'average_rating') is null);
  end;

  -- ===== acl_proacl_exact for the five new functions =====
  declare bad text := ''; f record;
  begin
    for f in select p.proname, coalesce((select string_agg(distinct case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end, ',' order by case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end) from aclexplode(p.proacl) a), 'NULL') g, p.prosecdef, p.provolatile, p.proconfig::text cfg
             from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('report_performance', 'report_ops_resolution', 'report_feedback', 'report_expenses_salary_by_staff', 'report_expenses_year_over_year') loop
      if f.g <> 'authenticated,postgres,service_role' or not f.prosecdef or f.provolatile <> 's' or f.cfg not like '%search_path=public%' then bad := bad || f.proname || '=' || f.g || ' '; end if;
    end loop;
    perform pg_temp.chk('acl_proacl_exact: 5 new functions = {postgres, authenticated, service_role}, SECURITY DEFINER STABLE search_path=public', bad = '' and
      (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('report_performance', 'report_ops_resolution', 'report_feedback', 'report_expenses_salary_by_staff', 'report_expenses_year_over_year')) = 5, bad);
  end;

  select string_agg(r3.line, E'\n' order by r3.n) into txt from pg_temp.res r3;
  raise exception E'RESULTS\n%', txt;
end $t$;
