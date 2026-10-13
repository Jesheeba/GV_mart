-- Rolled-back DB test for 20261020100000_amc_visits_unassigned_until_due.sql (assignment window, daily job, cron).
-- The visit schedule rule and assignment at sale have their own file: amc_visit_schedule_rule.test.sql.
-- Runner: BEGIN; the migration; this block (ends in RAISE; read RESULTS in the error). A throwaway __TEST_ organisation with
-- unroutable 555 numbers is created inside the transaction and vanishes with the rollback (nothing is committed, so there is
-- nothing to purge). No real customer, number, message or technician is touched; nothing is sent.
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
  v_org uuid; v_master uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid; v_custu uuid;
  v_c uuid; v_c2 uuid; v_c3 uuid; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_r jsonb; v_contract uuid; v_ids uuid[]; v_first uuid; v_second uuid; v_third uuid;
  v_job jsonb; n int; n2 int; s text; v_d date; v_ts timestamptz; v_kpi1 int; v_kpi2 int; v_expected int; v_ob1 int;
  v_contract2 uuid; v_contract3 uuid; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  -- ---------- schema, privileges, cron ----------
  perform pg_temp.chk('window setting defaults to 7 and is range-checked',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'amc_assign_window_days') = '7');
  perform pg_temp.chk('assign_due_amc_visits and the helpers are not executable by anon/authenticated',
    not has_function_privilege('anon', 'public.assign_due_amc_visits(timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'public.assign_due_amc_visits(timestamptz)', 'execute')
    and has_function_privilege('service_role', 'public.assign_due_amc_visits(timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'public._schedule_amc_visits(uuid,uuid,uuid,uuid,text,integer,integer,date,date,uuid,uuid,text,timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'public._amc_visit_date(date,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public._ticket_is_future_amc_visit(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.amc_assign_cron_tick(text)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('assign_due_amc_visits', '_schedule_amc_visits', '_amc_visit_date', '_ticket_is_future_amc_visit', 'amc_assign_cron_tick', '_amc_assign_deadman_check')));
  perform pg_temp.chk('cron: daily job at 06:30 IST (01:00 UTC) and dead-man at 08:30 IST (03:00 UTC), exact commands',
    (select count(*) from cron.job where jobname = 'amc-assign-due-visits' and schedule = '0 1 * * *' and command = 'select public.amc_assign_cron_tick()' and active) = 1
    and (select count(*) from cron.job where jobname = 'amc-assign-deadman' and schedule = '0 3 * * *' and command = 'select public._amc_assign_deadman_check()' and active) = 1);
  perform pg_temp.chk('the existing lead follow-up cron job is untouched',
    (select count(*) from cron.job where jobname = 'lead-followup-notifications' and schedule = '*/5 * * * *') = 1);
  perform pg_temp.chk('a heartbeat baseline exists', exists (select 1 from public.cron_job_heartbeats where job_key = 'amc_assign_due_visits'));
  perform pg_temp.chk('the four generators call the helper, and only the helper calls the engine for AMC visits',
    (select prosrc ~ '_auto_assign_ticket_internal' from pg_proc where proname = '_schedule_amc_visits' and pronamespace = 'public'::regnamespace) and
    (select prosrc !~ '_auto_assign_ticket_internal' and prosrc ~ '_schedule_amc_visits' from pg_proc where proname = 'sell_amc_plan' and pronamespace = 'public'::regnamespace)
    and (select prosrc !~ '_auto_assign_ticket_internal' and prosrc ~ '_schedule_amc_visits' from pg_proc where proname = 'sell_amc_plan_onsite' and pronamespace = 'public'::regnamespace)
    and (select prosrc !~ '_auto_assign_ticket_internal' and prosrc ~ '_schedule_amc_visits' from pg_proc where proname = 'renew_amc_plan' and pronamespace = 'public'::regnamespace)
    and (select prosrc ~ '_schedule_amc_visits' from pg_proc where proname = 'create_sale' and pronamespace = 'public'::regnamespace));

  -- ---------- throwaway organisation ----------
  insert into organizations (name) values ('__TEST_amc_window') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  v_custu := pg_temp.mkuser('customer', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ amc one', '5550100001') returning id into v_c;
  insert into customers (org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_ amc self', '5550100002', v_custu) returning id into v_c2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ amc sale', '5550100003') returning id into v_c3;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 3, 12000, 2) returning id into v_plan;
  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org;

  -- ---------- 1. sale: six visits, all open and unassigned ----------
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_c, v_prod, v_plan, v_today + 30, null, null);   -- visit 1 is 30 days out: nothing inside the window at sale
  perform pg_temp.as_pg();
  v_contract := (v_r ->> 'contract_id')::uuid;
  select count(*) into n from public.service_tickets where contract_id = v_contract;
  perform pg_temp.chk('1 a 3-year, 2-visits-a-year sale creates six visit tickets', n = 6, n::text);
  perform pg_temp.chk('1 every visit ticket is open, unassigned, with no SLA and no assigned_at',
    not exists (select 1 from public.service_tickets t where t.contract_id = v_contract and (t.status <> 'open' or t.sla_due_at is not null or t.assigned_at is not null))
    and not exists (select 1 from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and (a.technician_id is not null or a.status <> 'scheduled')));
  perform pg_temp.chk('1 visit_no is 1..6 and unique per contract',
    (select array_agg(visit_no order by visit_no) from public.service_tickets where contract_id = v_contract) = array[1, 2, 3, 4, 5, 6]);
  perform pg_temp.chk('1 the unique index refuses a duplicate visit_no',
    pg_temp.raises(format($q$update public.service_tickets set visit_no = 1 where contract_id = %L and visit_no = 2$q$, v_contract)) like '%duplicate key%');
  perform pg_temp.chk('1 dates follow the rule: visit k = start + (k - 1) x 6 months, rolled to a working day, at the slot start',
    (select bool_and((a.scheduled_at) = public._visit_start_ts(v_org, public._visit_working_day(v_org, (v_today + 30 + make_interval(months => 6 * (t.visit_no - 1)))::date)))
       from public.service_tickets t join public.appointments a on a.ticket_id = t.id where t.contract_id = v_contract));
  perform pg_temp.chk('1 no technician notification and no auto-assignment alert was raised at sale',
    not exists (select 1 from public.notifications n where n.org_id = v_org and n.type in ('ticket_auto_assigned', 'appointment_assigned', 'ticket_unassigned')));
  perform pg_temp.chk('1 no legacy milestone booked row and no automation ticket.created event for the visit tickets',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'milestone.booked') = 0
    and not exists (select 1 from public.automation_event_log where org_id = v_org and event_key = 'ticket.created')
    and exists (select 1 from public.automation_event_log where org_id = v_org and event_key = 'amc.joined'));
  perform pg_temp.chk('1 the sale notification and the contract are intact',
    exists (select 1 from public.notifications where org_id = v_org and type = 'amc_sold' and ref_id = v_contract)
    and (select status from public.amc_contracts where id = v_contract) = 'active');

  -- an ordinary ticket still gets its booked row (the skip is for contract visits only)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ ordinary') returning id into v_first;
  perform pg_temp.chk('1b an ordinary ticket still raises milestone.booked and ticket.created',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'milestone.booked' and ref_id = v_first) = 1
    and exists (select 1 from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and subject_id = v_first));

  -- ---------- 2. nothing is assigned until a visit is inside the window ----------
  v_r := public.assign_due_amc_visits(now());
  perform pg_temp.chk('2 today: nothing is inside the window, nothing is tried', (v_r ->> 'tried')::int = 0 and (v_r ->> 'assigned')::int = 0, v_r::text);
  select a.scheduled_at into v_ts from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and t.visit_no = 1;
  v_r := public.assign_due_amc_visits(v_ts - interval '10 days');
  perform pg_temp.chk('2 10 days before visit 1 (window 7): still nothing', (v_r ->> 'tried')::int = 0);
  v_r := public.assign_due_amc_visits(v_ts - interval '3 days');
  perform pg_temp.chk('2 3 days before visit 1: exactly that one visit is tried and assigned, the other five untouched',
    (v_r ->> 'tried')::int = 1 and (v_r ->> 'assigned')::int = 1
    and (select count(*) from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and a.technician_id is not null) = 1
    and (select t.status from public.service_tickets t where t.contract_id = v_contract and t.visit_no = 1) = 'assigned', v_r::text);
  perform pg_temp.chk('2 the assigned visit got an SLA from its own date, and the technician was notified',
    (select t.sla_due_at > v_ts from public.service_tickets t where t.contract_id = v_contract and t.visit_no = 1)
    and exists (select 1 from public.notifications where org_id = v_org and type = 'appointment_assigned'));
  v_r := public.assign_due_amc_visits(v_ts - interval '3 days');
  perform pg_temp.chk('2 running the job again assigns nothing more', (v_r ->> 'tried')::int = 0);
  perform pg_temp.chk('2 the "assigned" legacy milestone still goes out for the assigned visit (one row)',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'milestone.assigned') = 1);

  -- ---------- 3. no technician free: one alert, not one per run ----------
  select a.scheduled_at into v_ts from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and t.visit_no = 2;
  insert into technician_availability (org_id, technician_id, date, status)
  select v_org, x, (v_ts at time zone 'Asia/Kolkata')::date, 'leave' from unnest(array[v_tech1, v_tech2]) x;
  v_r := public.assign_due_amc_visits(v_ts - interval '2 days');
  perform pg_temp.chk('3 both technicians on leave: visit 2 is tried and stays unassigned', (v_r ->> 'tried')::int = 1 and (v_r ->> 'assigned')::int = 0 and (v_r ->> 'still_unassigned')::int = 1, v_r::text);
  v_r := public.assign_due_amc_visits(v_ts - interval '1 days');
  v_r := public.assign_due_amc_visits(v_ts);
  select count(*) into n from public.notifications n2 join public.service_tickets t on t.id = n2.ref_id
   where t.contract_id = v_contract and t.visit_no = 2 and n2.type = 'ticket_unassigned' and n2.is_read = false;
  perform pg_temp.chk('3 three daily runs leave exactly ONE unread "needs manual assignment" alert for that visit', n = 1, n::text);
  delete from technician_availability where org_id = v_org;
  v_r := public.assign_due_amc_visits(v_ts);
  perform pg_temp.chk('3 once a technician is free again, the next run assigns it', (v_r ->> 'assigned')::int = 1
    and (select t.status from public.service_tickets t where t.contract_id = v_contract and t.visit_no = 2) = 'assigned');

  -- ---------- 4. reschedule re-check ----------
  select a.id into v_second from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and t.visit_no = 3;
  select a.technician_id is null into s from public.appointments a where a.id = v_second;
  perform pg_temp.chk('4 setup: visit 3 is unassigned and far away', s = 'true' and public._ticket_is_future_amc_visit((select ticket_id from public.appointments where id = v_second)));
  update public.appointments set scheduled_at = public._visit_start_ts(v_org, public._visit_working_day(v_org, v_today + 30)) where id = v_second;
  perform pg_temp.chk('4 moved to 30 days from now: still outside the window, stays unassigned',
    (select technician_id is null from public.appointments where id = v_second));
  update public.appointments set scheduled_at = public._visit_start_ts(v_org, public._visit_working_day(v_org, v_today + 3)) where id = v_second;
  perform pg_temp.chk('4 moved to 3 days from now: assigned immediately by the reschedule trigger',
    (select technician_id is not null from public.appointments where id = v_second));

  -- ---------- 5. "not yet due" is excluded from the counts ----------
  select count(*) into n from public.service_tickets t where t.contract_id = v_contract and t.status = 'open' and public._ticket_is_future_amc_visit(t.id);
  perform pg_temp.chk('5 the remaining unassigned far visits (4..6) are "not yet due"; assigned or in-window ones are not', n = 3, n::text);
  perform pg_temp.chk('5 an ordinary open ticket is never "not yet due"', not public._ticket_is_future_amc_visit(v_first));
  perform pg_temp.as_user(v_master);
  v_kpi1 := (public.report_kpi_tiles(current_date - 30, current_date + 1) -> 'service' -> 'open_tickets' ->> 'count')::int;
  perform pg_temp.as_pg();
  select count(*) into v_expected from public.service_tickets t
   where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress') and not public.is_test_customer(t.customer_id)
     and not public._ticket_is_future_amc_visit(t.id);
  perform pg_temp.chk('5 KPI open_tickets equals the open tickets minus far-away AMC visits',
    v_kpi1 = v_expected and v_expected = (select count(*) from public.service_tickets where org_id = v_org and status in ('open','assigned','in_progress')) - 3,
    v_kpi1::text || ' vs ' || v_expected::text);
  -- the window setting is honoured: a visit 20 days away is "not yet due" at 7 days and due at 30
  select a.id into v_third from public.appointments a join public.service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and t.visit_no = 4;
  update public.appointments set scheduled_at = public._visit_start_ts(v_org, public._visit_working_day(v_org, v_today + 20)) where id = v_third;
  perform pg_temp.chk('5 20 days away with window 7: not yet due',
    public._ticket_is_future_amc_visit((select ticket_id from public.appointments where id = v_third)));
  update settings set amc_assign_window_days = 30 where org_id = v_org;
  perform pg_temp.chk('5 window 30: the same visit is now due',
    not public._ticket_is_future_amc_visit((select ticket_id from public.appointments where id = v_third)));
  v_r := public.assign_due_amc_visits(now());
  perform pg_temp.chk('5 and the job assigns it', (v_r ->> 'assigned')::int = 1 and (select technician_id is not null from public.appointments where id = v_third), v_r::text);
  update settings set amc_assign_window_days = 7 where org_id = v_org;
  perform pg_temp.chk('5 the window setting is range-checked',
    pg_temp.raises(format($q$update settings set amc_assign_window_days = 0 where org_id = %L$q$, v_org)) like '%check constraint%');

  -- ---------- 6. the other generators ----------
  -- on-site (technician) sale
  perform pg_temp.as_user(v_tp1);
  v_r := public.sell_amc_plan_onsite(v_org, v_c3, v_prod, v_plan, 'cash');
  perform pg_temp.as_pg();
  v_contract2 := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('6a on-site sale: six visits, visit_no 1..6',
    (select count(*) from public.service_tickets where contract_id = v_contract2) = 6
    and (select array_agg(visit_no order by visit_no) from public.service_tickets where contract_id = v_contract2) = array[1, 2, 3, 4, 5, 6]);
  -- customer self-service renewal (needs a payment reference)
  perform pg_temp.as_user(v_custu);
  v_r := public.renew_amc_plan(v_org, v_prod, v_plan, 'TEST-REF-1');
  perform pg_temp.as_pg();
  v_contract3 := (v_r ->> 'contract_id')::uuid;
  perform pg_temp.chk('6b customer renewal: six visits, visit_no 1..6',
    (select count(*) from public.service_tickets where contract_id = v_contract3) = 6
    and (select array_agg(visit_no order by visit_no) from public.service_tickets where contract_id = v_contract3) = array[1, 2, 3, 4, 5, 6]);
  -- create_sale AMC add-on
  perform pg_temp.as_user(v_master);
  v_r := public.create_sale(v_org, v_c3, jsonb_build_object('amc', jsonb_build_object('product_id', v_prod, 'plan_id', v_plan), 'payment_method', 'cash'));
  perform pg_temp.as_pg();
  v_ids := array(select jsonb_array_elements_text(v_r -> 'ticket_ids')::uuid);
  select count(*) into n from public.service_tickets t where t.id = any (v_ids) and t.type = 'amc' and t.contract_id is not null;
  perform pg_temp.chk('6c create_sale AMC add-on: six visits with visit numbers', n = 6
    and not exists (select 1 from public.service_tickets t where t.id = any (v_ids) and t.type = 'amc' and t.visit_no is null), n::text);
  -- These sales start today, so only visit 1 is inside the window: it was attempted at sale (assigned, or one "needs manual
  -- assignment" alert - which of the two depends on whether the test runs before or after closing time, because after closing
  -- the visit moves to tomorrow where attendance is not required). Visits 2..6 are months away: untouched, no alert.
  perform pg_temp.chk('6 for all three generators visit 1 was attempted at sale and visits 2..6 are untouched',
    (select bool_and(
        (a1.technician_id is not null or exists (select 1 from public.notifications nn where nn.type = 'ticket_unassigned' and nn.ref_id = t1.id))
        and not exists (select 1 from public.appointments ax join public.service_tickets tx on tx.id = ax.ticket_id
                         where tx.contract_id = t1.contract_id and tx.visit_no > 1 and ax.technician_id is not null)
        and not exists (select 1 from public.notifications nn join public.service_tickets tx on tx.id = nn.ref_id
                         where tx.contract_id = t1.contract_id and tx.visit_no > 1 and nn.type = 'ticket_unassigned'))
       from public.service_tickets t1 join public.appointments a1 on a1.ticket_id = t1.id
      where t1.visit_no = 1 and (t1.contract_id in (v_contract2, v_contract3) or t1.id = any (v_ids))));

  -- ---------- 7. heartbeat and dead-man ----------
  -- 7a. the very first dead-man run, BEFORE any tick has written a heartbeat: the migration's baseline row must keep it quiet
  select count(*) into n from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%';
  perform pg_temp.chk('7a baseline heartbeat from the migration: fresh (within 2 minutes), status ok, never alerted',
    (select last_status = 'ok' and last_run_at > now() - interval '2 minutes' and last_stale_alert_at is null
       from public.cron_job_heartbeats where job_key = 'amc_assign_due_visits'));
  perform public._amc_assign_deadman_check();
  perform pg_temp.chk('7a FIRST dead-man run before any tick raises NO alert',
    (select count(*) from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%') = n);
  -- 7b. no heartbeat row at all (nothing to judge): quiet
  delete from public.cron_job_heartbeats where job_key = 'amc_assign_due_visits';
  perform public._amc_assign_deadman_check();
  perform pg_temp.chk('7b no heartbeat row at all raises NO alert',
    (select count(*) from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%') = n);
  -- 7c. thresholds: a 25 hour old ok heartbeat is fine (a daily job plus slack), a 27 hour old one is not
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status) values ('amc_assign_due_visits', now() - interval '25 hours', 'ok');
  perform public._amc_assign_deadman_check();
  perform pg_temp.chk('7c a 25-hour-old ok heartbeat raises NO alert',
    (select count(*) from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%') = n);
  update public.cron_job_heartbeats set last_run_at = now() - interval '27 hours' where job_key = 'amc_assign_due_visits';
  perform public._amc_assign_deadman_check();
  perform pg_temp.chk('7c a 27-hour-old heartbeat raises an alert',
    (select count(*) from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%') > n);
  update public.cron_job_heartbeats set last_run_at = now(), last_status = 'ok', last_stale_alert_at = null where job_key = 'amc_assign_due_visits';
  perform public.amc_assign_cron_tick();
  perform pg_temp.chk('7 the tick writes an ok heartbeat',
    (select last_status from public.cron_job_heartbeats where job_key = 'amc_assign_due_visits') = 'ok');
  update public.cron_job_heartbeats set last_run_at = now() - interval '30 hours', last_stale_alert_at = null where job_key = 'amc_assign_due_visits';
  select count(*) into n from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%';
  perform public._amc_assign_deadman_check();
  select count(*) into n2 from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%';
  perform pg_temp.chk('7 dead-man: a heartbeat older than 26 h raises a master alert, once', n2 > n);
  perform public._amc_assign_deadman_check();
  perform pg_temp.chk('7 and not again within 24 hours',
    (select count(*) from public.notifications where type = 'cron_job_stale' and body like 'amc_assign_due_visits%') = n2);
  update public.cron_job_heartbeats set last_run_at = now(), last_stale_alert_at = null, last_status = 'ok' where job_key = 'amc_assign_due_visits';

  -- ---------- 8. real data untouched ----------
  perform pg_temp.chk('8 no real organisation row was touched (only the throwaway org has new AMC tickets)',
    not exists (select 1 from public.service_tickets t join public.organizations o on o.id = t.org_id
                 where o.name not like '\_\_TEST\_%' and t.created_at > now() - interval '5 minutes'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
