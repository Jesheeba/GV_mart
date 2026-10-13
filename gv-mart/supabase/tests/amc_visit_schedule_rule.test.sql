-- Rolled-back DB test for the AMC visit schedule rule and assignment at sale
-- (migration 20261020100000_amc_visits_unassigned_until_due.sql: _amc_visit_date, _schedule_amc_visits).
-- Runner: BEGIN; the migration; this block (ends in RAISE; read RESULTS in the error). A throwaway __TEST_ organisation with
-- unroutable 555 numbers is created inside the transaction and vanishes with the rollback; nothing is sent, no real data touched.
-- Time-of-day cases call the helper directly with a fixed p_now so the test does not depend on when it runs.
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
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_cs uuid[] := '{}'; v_cx uuid; ci integer;
  v_brand uuid; v_model uuid; v_prod uuid; v_p4 uuid; v_p5 uuid; v_p2x3 uuid; v_p12 uuid;
  v_r jsonb; v_k uuid; v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_working_today boolean; v_d date; v_start date; v_exp date; v_ids uuid[]; n int; s text;
  v_first uuid;
  v_now timestamptz;
begin
  -- ---------- A. the date rule, as a pure function ----------
  perform pg_temp.chk('A 4 visits a year from 1 Jan: Jan, Apr, Jul, Oct (visit 1 on the start date)',
    (select array_agg(public._amc_visit_date(date '2027-01-01', 4, k) order by k) from generate_series(1, 4) k)
      = array[date '2027-01-01', date '2027-04-01', date '2027-07-01', date '2027-10-01']);
  perform pg_temp.chk('A 2 visits a year, 3 years: every 6 months, the last one 6 months before expiry',
    (select array_agg(public._amc_visit_date(date '2027-01-13', 2, k) order by k) from generate_series(1, 6) k)
      = array[date '2027-01-13', date '2027-07-13', date '2028-01-13', date '2028-07-13', date '2029-01-13', date '2029-07-13']);
  perform pg_temp.chk('A 1 visit a year: visit 1 is the start date, visit 2 a year later',
    public._amc_visit_date(date '2027-05-20', 1, 1) = date '2027-05-20' and public._amc_visit_date(date '2027-05-20', 1, 2) = date '2028-05-20');
  perform pg_temp.chk('A 12 visits a year from 31 Jan: whole months from the START (28 Feb, then 31 Mar: no drift)',
    public._amc_visit_date(date '2027-01-31', 12, 1) = date '2027-01-31'
    and public._amc_visit_date(date '2027-01-31', 12, 2) = date '2027-02-28'
    and public._amc_visit_date(date '2027-01-31', 12, 3) = date '2027-03-31');
  perform pg_temp.chk('A 5 visits a year (gap 2.4 months): fractional part added as days',
    (select array_agg(public._amc_visit_date(date '2027-03-01', 5, k) order by k) from generate_series(1, 5) k)
      = array[date '2027-03-01', date '2027-05-13', date '2027-07-25', date '2027-10-07', date '2027-12-19']);
  perform pg_temp.chk('A 24 visits a year (gap half a month): no two visits on the same day',
    public._amc_visit_date(date '2027-01-01', 24, 2) = date '2027-01-16' and public._amc_visit_date(date '2027-01-01', 24, 3) = date '2027-02-01');
  perform pg_temp.chk('A the old month-offset helper is untouched (rentals still use it)',
    exists (select 1 from pg_proc where proname = '_visit_month_offset' and pronamespace = 'public'::regnamespace));

  -- ---------- throwaway organisation ----------
  insert into organizations (name) values ('__TEST_amc_rule') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update settings set work_start = time '09:15', work_end = time '17:30' where org_id = v_org;   -- the shop's real hours
  v_master := pg_temp.mkuser('master', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  for ci in 1..16 loop
    insert into customers (org_id, name, mobile) values (v_org, '__TEST_ rule ' || ci, '55502' || lpad(ci::text, 5, '0')) returning id into v_cx;
    v_cs := array_append(v_cs, v_cx);
  end loop;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ 1y 4v', 1, 4000, 4) returning id into v_p4;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ 1y 5v', 1, 5000, 5) returning id into v_p5;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ 3y 2v', 3, 12000, 2) returning id into v_p2x3;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ 1y 12v', 1, 6000, 12) returning id into v_p12;
  v_working_today := public._visit_working_day(v_org, v_today) = v_today;

  -- ---------- B. a real sale far enough out that nothing is inside the window ----------
  v_start := v_today + 60;
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[1], v_prod, v_p4, v_start, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  select expiry_date into v_exp from public.amc_contracts where id = v_k;
  perform pg_temp.chk('B 1 year x 4 visits = 4 visit tickets, visit_no 1..4',
    (select array_agg(visit_no order by visit_no) from public.service_tickets where contract_id = v_k) = array[1, 2, 3, 4]);
  perform pg_temp.chk('B visit k = start + (k - 1) x 3 months, rolled to a working day, at the slot start',
    (select bool_and(a.scheduled_at = public._visit_start_ts(v_org, public._visit_working_day(v_org, (v_start + make_interval(months => 3 * (t.visit_no - 1)))::date)))
       from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k));
  perform pg_temp.chk('B visit 1 is on the plan start date (rolled only if that is a non-working day)',
    (select (a.scheduled_at at time zone 'Asia/Kolkata')::date from public.service_tickets t join public.appointments a on a.ticket_id = t.id
       where t.contract_id = v_k and t.visit_no = 1) = public._visit_working_day(v_org, v_start));
  perform pg_temp.chk('B the last visit falls well before expiry (about one gap, not on the expiry day)',
    (select max((a.scheduled_at at time zone 'Asia/Kolkata')::date) from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k) < v_exp - 60);
  perform pg_temp.chk('B next_service_date is the date of visit 1',
    (select c.next_service_date from public.amc_contracts c where c.id = v_k) = public._visit_working_day(v_org, v_start));
  perform pg_temp.chk('B nothing is inside the window: all open and unassigned, no SLA, no alert',
    not exists (select 1 from public.service_tickets t where t.contract_id = v_k and (t.status <> 'open' or t.sla_due_at is not null or t.assigned_at is not null))
    and not exists (select 1 from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_k and a.technician_id is not null)
    and not exists (select 1 from public.notifications n where n.org_id = v_org and n.type in ('ticket_unassigned', 'ticket_auto_assigned', 'appointment_assigned')));
  perform pg_temp.chk('B all four are "not yet due" (they wait for the daily job)',
    (select count(*) from public.service_tickets t where t.contract_id = v_k and public._ticket_is_future_amc_visit(t.id)) = 4);

  -- a 3-year, 2-visits-a-year plan: 6 visits, the last at 30 months, six months before expiry
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[2], v_prod, v_p2x3, v_today + 60, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('B 3 years x 2 visits = 6 visits; visit 1 = start, visit 6 = start + 30 months (not the expiry day)',
    (select count(*) from public.service_tickets where contract_id = v_k) = 6
    and (select (a.scheduled_at at time zone 'Asia/Kolkata')::date from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 6)
        = public._visit_working_day(v_org, (v_today + 60 + interval '30 months')::date)
    and (select max((a.scheduled_at at time zone 'Asia/Kolkata')::date) from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k)
        < (select expiry_date from public.amc_contracts where id = v_k) - 150);

  -- ---------- C. assignment at sale ----------
  -- a technician is checked in today
  insert into attendance (org_id, technician_id, date, check_in_at) values (v_org, v_tech1, v_today, now());

  -- C1. a visit dated TODAY is assigned at sale (the helper is called with a fixed clock of 10:00 IST so this does not depend on
  -- the time of day the test runs; a non-working today rolls the visit to the next working day, where no check-in is needed)
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[3], v_prod, v_p4, v_today, v_today + interval '1 year', 'active') returning id into v_k;
  v_now := (v_today + time '10:00') at time zone 'Asia/Kolkata';
  v_ids := public._schedule_amc_visits(v_org, v_cs[3], v_k, v_prod, '__TEST_ plan', 4, 4, v_today, (v_today + interval '1 year')::date, null, null, 'call', v_now);
  perform pg_temp.chk('C1 four visits created', coalesce(array_length(v_ids, 1), 0) = 4);
  perform pg_temp.chk('C1 visit 1 (today) was assigned AT SALE to the checked-in technician; ticket is assigned, with an SLA',
    (select a.technician_id = v_tech1 and t.status = 'assigned' and t.sla_due_at is not null
       from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1),
    (select coalesce(t.status::text, '') || ' ' || coalesce(a.technician_id::text, 'no tech') from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  perform pg_temp.chk('C1 no "needs manual assignment" alert, and the technician was notified',
    not exists (select 1 from public.notifications n join public.service_tickets t on t.id = n.ref_id where t.contract_id = v_k and n.type = 'ticket_unassigned')
    and exists (select 1 from public.notifications n join public.appointments a on a.id = n.ref_id join public.service_tickets t on t.id = a.ticket_id
                 where t.contract_id = v_k and n.type = 'appointment_assigned'));
  perform pg_temp.chk('C1 visits 2..4 (3, 6 and 9 months away) stay open and unassigned',
    (select count(*) from public.service_tickets t join public.appointments a on a.ticket_id = t.id
      where t.contract_id = v_k and t.visit_no > 1 and t.status = 'open' and a.technician_id is null) = 3);
  perform pg_temp.chk('C1 when today is a working day, visit 1 is scheduled at 10:00 IST (the clock given), not in the past',
    not v_working_today
    or (select (a.scheduled_at at time zone 'Asia/Kolkata')::time = time '10:00' from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  perform pg_temp.chk('C1 next_service_date is the date of visit 1',
    (select c.next_service_date from public.amc_contracts c where c.id = v_k) = public._visit_working_day(v_org, v_today));

  -- C2. nobody checked in (and today is a working day): visit 1 stays unassigned and exactly one alert fires; the sale is not blocked
  delete from attendance where org_id = v_org;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[4], v_prod, v_p4, v_today, v_today + interval '1 year', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[4], v_k, v_prod, '__TEST_ plan', 4, 4, v_today, (v_today + interval '1 year')::date, null, null, 'call', v_now);
  select count(*) into n from public.notifications nn join public.service_tickets t on t.id = nn.ref_id where t.contract_id = v_k and nn.type = 'ticket_unassigned';
  if v_working_today then
    perform pg_temp.chk('C2 no technician checked in: visit 1 stays unassigned and ONE alert fires for it; all four visits exist',
      array_length(v_ids, 1) = 4 and n = 1
      and (select a.technician_id is null from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1)
      and exists (select 1 from public.notifications nn join public.service_tickets t on t.id = nn.ref_id
                   where t.contract_id = v_k and t.visit_no = 1 and nn.type = 'ticket_unassigned' and nn.role = 'operation_admin'), n::text);
  else
    perform pg_temp.chk('C2 (today is a day off, so visit 1 moved to the next working day where no check-in is needed): assigned, no alert',
      array_length(v_ids, 1) = 4 and n = 0);
  end if;

  -- C3. a visit a few days out, inside the window: assigned at sale (no check-in needed for a future date); leave is respected
  v_start := v_today + 3;
  v_d := public._visit_working_day(v_org, v_start);
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[5], v_prod, v_p4, v_start, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('C3 visit 1 three days out is inside the window: assigned at sale; visits 2..4 are not',
    (select a.technician_id is not null from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1)
    and (select count(*) from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_k and a.technician_id is not null) = 1);

  insert into technician_availability (org_id, technician_id, date, status)
  select v_org, x, public._visit_working_day(v_org, v_today + 4), 'leave' from unnest(array[v_tech1, v_tech2]) x;
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[6], v_prod, v_p4, v_today + 4, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('C3 both technicians on leave on visit 1''s date: unassigned at sale and one alert; sale not blocked',
    (select a.technician_id is null from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1)
    and (select count(*) from public.notifications nn join public.service_tickets t on t.id = nn.ref_id where t.contract_id = v_k and nn.type = 'ticket_unassigned') = 1
    and (select count(*) from public.service_tickets where contract_id = v_k) = 4);
  delete from technician_availability where org_id = v_org;

  -- C4. capacity is respected: a technician with no spare minutes is not given the visit
  update technicians set daily_capacity_minutes = 1 where org_id = v_org;
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[7], v_prod, v_p4, v_today + 2, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('C4 no daily capacity left: unassigned at sale with one alert',
    (select a.technician_id is null from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1)
    and (select count(*) from public.notifications nn join public.service_tickets t on t.id = nn.ref_id where t.contract_id = v_k and nn.type = 'ticket_unassigned') = 1);
  update technicians set daily_capacity_minutes = 480 where org_id = v_org;

  -- C5. the window setting decides what is assigned at sale
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[8], v_prod, v_p12, v_today + 20, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('C5 window 7, visit 1 twenty days out: not assigned at sale, no alert',
    (select count(*) from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_k and a.technician_id is not null) = 0
    and not exists (select 1 from public.notifications nn join public.service_tickets t on t.id = nn.ref_id where t.contract_id = v_k and nn.type = 'ticket_unassigned'));
  update settings set amc_assign_window_days = 30 where org_id = v_org;
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cs[9], v_prod, v_p12, v_today + 20, null, null);
  perform pg_temp.as_pg();
  v_k := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('C5 window 30, same plan and date: visit 1 (20 days out) and visit 2 (one month later is 50 days out, beyond) - only visit 1 assigned',
    (select count(*) from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_k and a.technician_id is not null) = 1);
  update settings set amc_assign_window_days = 7 where org_id = v_org;

  -- ---------- D. time of day and back-dated sales (fixed clocks) ----------
  -- D1. sold at 10:31 on a working Tuesday: the visit starts at the next quarter hour, 10:45
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[10], v_prod, v_p4, date '2027-03-02', date '2028-03-02', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[10], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-02', date '2028-03-02', null, null, 'call', timestamptz '2027-03-02 10:31:00+05:30');
  perform pg_temp.chk('D1 sold at 10:31: visit 1 starts at 10:45, same day',
    (select a.scheduled_at = timestamptz '2027-03-02 10:45:00+05:30' from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  -- D2. exactly on a quarter, and one second past it
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[11], v_prod, v_p4, date '2027-03-02', date '2028-03-02', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[11], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-02', date '2028-03-02', null, null, 'call', timestamptz '2027-03-02 10:30:00+05:30');
  perform pg_temp.chk('D2 sold at exactly 10:30: starts at 10:30',
    (select a.scheduled_at = timestamptz '2027-03-02 10:30:00+05:30' from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[12], v_prod, v_p4, date '2027-03-02', date '2028-03-02', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[12], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-02', date '2028-03-02', null, null, 'call', timestamptz '2027-03-02 10:30:20+05:30');
  perform pg_temp.chk('D2 sold at 10:30:20: starts at 10:45 (never in the past)',
    (select a.scheduled_at = timestamptz '2027-03-02 10:45:00+05:30' from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  -- D3. after closing time (work_end 17:30): visit 1 moves to the next working day at the slot start
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[13], v_prod, v_p4, date '2027-03-02', date '2028-03-02', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[13], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-02', date '2028-03-02', null, null, 'call', timestamptz '2027-03-02 18:00:00+05:30');
  perform pg_temp.chk('D3 sold at 18:00 (after closing): visit 1 is the next working day at the slot start',
    (select a.scheduled_at = public._visit_start_ts(v_org, date '2027-03-03') from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1),
    (select string_agg(t.visit_no || '=' || (a.scheduled_at at time zone 'Asia/Kolkata')::text, ', ' order by t.visit_no) from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k));
  perform pg_temp.chk('D3 next_service_date follows the moved visit',
    (select c.next_service_date from public.amc_contracts c where c.id = v_k) = date '2027-03-03');
  -- D4. before opening: the slot start, same day
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[14], v_prod, v_p4, date '2027-03-02', date '2028-03-02', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[14], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-02', date '2028-03-02', null, null, 'call', timestamptz '2027-03-02 08:00:00+05:30');
  perform pg_temp.chk('D4 sold at 08:00 (before opening): visit 1 is today at the slot start',
    (select a.scheduled_at = public._visit_start_ts(v_org, date '2027-03-02') from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  -- D5. a Sunday start rolls forward like every other visit
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[15], v_prod, v_p4, date '2027-03-07', date '2028-03-07', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[15], v_k, v_prod, '__TEST_ plan', 4, 4, date '2027-03-07', date '2028-03-07', null, null, 'call', timestamptz '2027-03-02 10:00:00+05:30');
  perform pg_temp.chk('D5 start date on a Sunday: visit 1 is Monday 8 March',
    (select (a.scheduled_at at time zone 'Asia/Kolkata')::date = date '2027-03-08' from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_k and t.visit_no = 1));
  -- D6. back-dated sale: visit 1 (1 Dec 2026) is before "today" (2 Mar 2027) and is not created; its number is kept
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cs[16], v_prod, v_p2x3, date '2026-12-01', date '2029-12-01', 'active') returning id into v_k;
  v_ids := public._schedule_amc_visits(v_org, v_cs[16], v_k, v_prod, '__TEST_ plan', 2, 6, date '2026-12-01', date '2029-12-01', null, null, 'call', timestamptz '2027-03-02 10:00:00+05:30');
  perform pg_temp.chk('D6 back-dated: visit 1 (1 Dec 2026) is skipped, visits 2..6 are created with their own numbers',
    (select array_agg(visit_no order by visit_no) from public.service_tickets where contract_id = v_k) = array[2, 3, 4, 5, 6]
    and (select name_of_complaint from public.service_tickets where contract_id = v_k and visit_no = 2) = 'AMC scheduled service 2 of 6');
  perform pg_temp.chk('D6 next_service_date is the first visit that exists (1 Jun 2027)',
    (select c.next_service_date from public.amc_contracts c where c.id = v_k) = date '2027-06-01');

  -- ---------- E. real data untouched ----------
  perform pg_temp.chk('E no real organisation row was touched',
    not exists (select 1 from public.service_tickets t join public.organizations o on o.id = t.org_id
                 where o.name not like '\_\_TEST\_%' and t.created_at > now() - interval '5 minutes'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
