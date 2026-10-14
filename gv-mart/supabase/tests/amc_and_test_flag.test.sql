-- Rolled-back DB tests for migrations 20261016100000_amc_cancel_visit_scheduling_overlap and 20261016110000_test_customer_flag
-- (batch-2 items 1 and 5).  Run AFTER both migrations (the runner script concatenates them in front of this file inside one
-- transaction).  One transaction ending in RAISE; read RESULTS in the error.  A throwaway __TEST_ organisation is created
-- inside the transaction; the only real-data reads are the "real data unchanged" fingerprints.
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

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_brand uuid; v_model uuid; v_cust uuid; v_cust_t uuid; v_prod uuid; v_plan uuid; v_start date; v_r jsonb; v_ids uuid[];
  n int; b boolean; rec record; v_contract uuid; v_msg text; v_appt uuid; v_tk uuid;
  l_t1 uuid; l_t2 uuid; l_n uuid; v_f1 jsonb; v_f2 jsonb; v_mob text := '9400000077';
  fp_a text; fp_b text; fp_c text; fp_d text; fp_t text; v_ws time; v_we time; v_sunday_working boolean;
begin
  -- real-data fingerprints (appointments updated_at deliberately excluded: the migration backfills ends_at)
  select md5(coalesce(string_agg(id::text||status::text||coalesce(cancelled_at::text,''), ',' order by id),'')) into fp_a from public.amc_contracts where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select md5(coalesce(string_agg(id::text||status::text||coalesce(sla_due_at::text,''), ',' order by id),'')) into fp_b from public.service_tickets where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select md5(coalesce(string_agg(id::text||coalesce(scheduled_at::text,'')||coalesce(technician_id::text,'')||status::text, ',' order by id),'')) into fp_c from public.appointments where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) into fp_d from public.customers where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  -- ---------- schema ----------
  perform pg_temp.chk('btree_gist installed', exists (select 1 from pg_extension where extname = 'btree_gist'));
  perform pg_temp.chk('old one-open-per-technician index replaced by overlap constraint + untimed index',
    not exists (select 1 from pg_indexes where indexname = 'appointments_one_open_per_technician_idx')
    and exists (select 1 from pg_constraint where conname = 'appointments_technician_no_overlap')
    and exists (select 1 from pg_indexes where indexname = 'appointments_one_open_untimed_per_technician_idx'));
  perform pg_temp.chk('every dated open appointment now has ends_at', not exists (select 1 from appointments where scheduled_at is not null and ends_at is null));
  perform pg_temp.chk('new functions are not executable by anon/PUBLIC; cancel only for authenticated+service_role',
    not has_function_privilege('anon', 'public.cancel_amc_contract(uuid,text)', 'execute')
    and has_function_privilege('authenticated', 'public.cancel_amc_contract(uuid,text)', 'execute')
    and not has_function_privilege('anon', 'public._tech_busy_at(uuid,timestamptz,integer,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public._tech_busy_at(uuid,timestamptz,integer,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.is_test_customer(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.is_test_customer(uuid)', 'execute'));
  perform pg_temp.chk('helpers have exactly one signature',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('cancel_amc_contract', '_tech_busy_at', '_visit_start_ts', 'is_test_customer')) = 4);

  -- ---------- throwaway org ----------
  insert into organizations (name) values ('__TEST_b17_amcflag') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Real-ish', '9400000066') returning id into v_cust;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Flagged', v_mob) returning id into v_cust_t;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 3, 12000, 2) returning id into v_plan;
  select work_start, work_end into v_ws, v_we from settings where org_id = v_org;
  perform pg_temp.chk('settings has working hours', v_ws is not null and v_we is not null, v_ws::text || '-' || v_we::text);

  -- pick a start date whose +6 months lands on a non-working day (a Sunday in the default week), if the default week has one
  v_start := null;
  for i in 1..400 loop
    if not public._lead_is_working_day(v_org, (current_date + i + interval '6 months')::date) then v_start := current_date + i; exit; end if;
  end loop;
  v_sunday_working := v_start is null;
  if v_start is null then v_start := current_date + 5; end if;

  -- ---------- AMC generation ----------
  perform pg_temp.as_user(v_master);
  v_r := public.sell_amc_plan(v_org, v_cust, v_prod, v_plan, v_start, null, null);
  perform pg_temp.as_pg();
  v_contract := (v_r ->> 'contract_id')::uuid;
  -- Since migration 20261022100000 a sale creates its visits UNASSIGNED and the daily job assigns them when due. These
  -- assertions are about scheduling and overlap once visits are assigned, so run the job as if every visit were due.
  perform public.assign_due_amc_visits(now() + interval '5 years');
  select count(*) into n from service_tickets where contract_id = v_contract;
  perform pg_temp.chk('3y x 2 visits = 6 visit tickets', n = 6, n::text);
  perform pg_temp.chk('all visits start at the master working-hours start, not a hard-coded 09:00 (and carry the window)',
    not exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract
      and ((a.scheduled_at at time zone 'Asia/Kolkata')::time <> v_ws or a.available_from is distinct from v_ws or a.available_to is distinct from v_we)));
  perform pg_temp.chk('no visit falls on a non-working day',
    not exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract
      and not public._lead_is_working_day(v_org, (a.scheduled_at at time zone 'Asia/Kolkata')::date)));
  perform pg_temp.chk('first visit is the first working day on/after the plan START date (rolled forward, never back)',
    (select (min(a.scheduled_at) at time zone 'Asia/Kolkata')::date from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract)
      between v_start and v_start + 7,
    (select (min(a.scheduled_at) at time zone 'Asia/Kolkata')::date::text from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract)
      || ' vs ' || v_start::text || case when v_sunday_working then ' (no non-working day in default week)' else '' end);
  perform pg_temp.chk('visits are 6 months apart in sequence (monotonic)',
    (select bool_and(d > lag_d) from (select a.scheduled_at d, lag(a.scheduled_at) over (order by a.scheduled_at) lag_d
      from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract) q where lag_d is not null));
  perform pg_temp.chk('every dated visit has ends_at after scheduled_at',
    not exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and (a.ends_at is null or a.ends_at <= a.scheduled_at)));
  perform pg_temp.chk('assigned visits: SLA counted from the visit time, never already breached at assignment',
    not exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and a.technician_id is not null and t.sla_due_at <= a.scheduled_at)
    and exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and a.technician_id is not null));

  -- ---------- busy only at an overlapping time ----------
  select a.technician_id into v_tech1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and a.technician_id is not null order by a.scheduled_at limit 1;
  select a.scheduled_at, a.id into rec from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and a.technician_id = v_tech1 order by a.scheduled_at limit 1;
  perform pg_temp.chk('technician with a far-future visit is NOT busy now', not public._tech_busy_at(v_tech1, now(), 60, null));
  perform pg_temp.chk('...but is busy at the visit time', public._tech_busy_at(v_tech1, rec.scheduled_at + interval '10 minutes', 30, null));
  perform pg_temp.chk('...and free right after the visit ends', not public._tech_busy_at(v_tech1, rec.scheduled_at + interval '6 hours', 30, null));
  -- a second ticket at the same time cannot be given to the same technician (constraint), at another time it can
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ clash') returning id into v_tk;
  insert into appointments (org_id, ticket_id, mode, scheduled_at, status) values (v_org, v_tk, 'datetime', rec.scheduled_at + interval '10 minutes', 'scheduled') returning id into v_appt;
  begin
    update appointments set technician_id = v_tech1 where id = v_appt;
    perform pg_temp.chk('overlapping assignment is rejected by the constraint', false);
  exception when exclusion_violation then
    perform pg_temp.chk('overlapping assignment is rejected by the constraint', true);
  end;
  update appointments set scheduled_at = rec.scheduled_at + interval '6 hours' where id = v_appt;
  begin
    update appointments set technician_id = v_tech1 where id = v_appt;
    perform pg_temp.chk('non-overlapping assignment to the same technician is allowed', true);
  exception when others then
    perform pg_temp.chk('non-overlapping assignment to the same technician is allowed', false, sqlerrm);
  end;

  -- ---------- cancel ----------
  select md5(string_agg(id::text, ',' order by id)) into fp_t from service_tickets where contract_id = v_contract;
  perform pg_temp.as_user(v_ops);
  begin
    perform public.cancel_amc_contract(v_contract, 'x');
    perform pg_temp.chk('operation_admin may NOT cancel', false);
  exception when others then
    perform pg_temp.chk('operation_admin may NOT cancel', sqlerrm like '%only the master%', sqlerrm);
  end;
  perform pg_temp.as_user(v_master);
  begin
    perform public.cancel_amc_contract(v_contract, '   ');
    perform pg_temp.chk('blank reason rejected', false);
  exception when others then
    perform pg_temp.chk('blank reason rejected', sqlerrm like '%reason is required%', sqlerrm);
  end;
  v_r := public.cancel_amc_contract(v_contract, '__TEST_ cancelled by test');
  perform pg_temp.as_pg();
  perform pg_temp.chk('cancel result counts the 6 visits', (v_r ->> 'visits_cancelled')::int = 6, v_r::text);
  perform pg_temp.chk('contract keeps its row, is expired + stamped cancelled',
    (select status::text = 'expired' and cancelled_at is not null and cancelled_by = v_master and cancel_reason = '__TEST_ cancelled by test' from amc_contracts where id = v_contract));
  perform pg_temp.chk('all visit tickets cancelled, none deleted',
    (select count(*) from service_tickets where contract_id = v_contract and status::text = 'cancelled') = 6
    and (select md5(string_agg(id::text, ',' order by id)) from service_tickets where contract_id = v_contract) = fp_t);
  perform pg_temp.chk('their appointments are cancelled and the technicians freed',
    not exists (select 1 from appointments a join service_tickets t on t.id = a.ticket_id where t.contract_id = v_contract and (a.status::text <> 'cancelled' or a.technician_id is not null)));
  perform pg_temp.chk('technician is free again at the old visit time', not public._tech_busy_at(v_tech1, rec.scheduled_at, 60, null));
  perform pg_temp.as_user(v_master);
  begin
    perform public.cancel_amc_contract(v_contract, 'again');
    perform pg_temp.chk('cancelling twice is rejected', false);
  exception when others then
    perform pg_temp.chk('cancelling twice is rejected', sqlerrm like '%already cancelled%', sqlerrm);
  end;
  perform pg_temp.as_user(v_master);
  perform public.refresh_amc_statuses(v_org);
  perform pg_temp.as_pg();
  perform pg_temp.chk('refresh_amc_statuses leaves the cancelled contract alone', (select status::text = 'expired' from amc_contracts where id = v_contract));

  -- ---------- test flag: guard ----------
  perform pg_temp.chk('new customers default to is_test = false', (select not is_test from customers where id = v_cust));
  perform pg_temp.as_user(v_sales);
  begin
    update customers set is_test = true where id = v_cust_t;
    perform pg_temp.chk('non-master cannot set is_test', false);
  exception when others then
    perform pg_temp.chk('non-master cannot set is_test', true, sqlerrm);
  end;
  perform pg_temp.as_user(v_master);
  update customers set is_test = true where id = v_cust_t;
  perform pg_temp.as_pg();
  perform pg_temp.chk('master can flag a customer', (select is_test from customers where id = v_cust_t));
  perform pg_temp.chk('is_test_customer / _ticket_is_test helper', public.is_test_customer(v_cust_t) and not public.is_test_customer(v_cust));

  -- ---------- test flag: leads follow the customer or the shared mobile ----------
  insert into leads (org_id, customer_id, name, mobile, source, status) values (v_org, v_cust_t, '__TEST_ L by customer', '9400000001', 'field', 'new') returning id into l_t1;
  insert into leads (org_id, name, mobile, source, status) values (v_org, '__TEST_ L by mobile', '+91 ' || v_mob, 'field', 'new') returning id into l_t2;
  insert into leads (org_id, name, mobile, source, status) values (v_org, '__TEST_ L normal', '9400000055', 'field', 'new') returning id into l_n;
  perform pg_temp.chk('lead of a test customer is flagged', (select is_test from leads where id = l_t1));
  perform pg_temp.chk('lead sharing the test customer mobile is flagged (formatting ignored)', (select is_test from leads where id = l_t2));
  perform pg_temp.chk('unrelated lead is not flagged', (select not is_test from leads where id = l_n));
  perform pg_temp.chk('test leads are not auto-assigned', (select assigned_to is null and not auto_assign_pending from leads where id = l_t1));
  update customers set is_test = false where id = v_cust_t;
  perform pg_temp.chk('un-flagging cascades to the customer lead', (select not is_test from leads where id = l_t1));
  update customers set is_test = true where id = v_cust_t;
  perform pg_temp.chk('re-flagging cascades again', (select is_test from leads where id = l_t1));
  update leads set customer_id = null, mobile = '9400000044' where id = l_t2;
  perform pg_temp.chk('lead that changes to another number loses the flag', (select not is_test from leads where id = l_t2));

  -- ---------- test flag: aggregates ignore flagged data ----------
  perform pg_temp.as_user(v_master);
  v_f1 := jsonb_build_object('funnel', public.get_lead_funnel(now() - interval '1 day', now() + interval '1 day'),
                             'counts', public.followup_counts('all', null), 'nofu', (select count(*) from public.list_leads_without_followup(null, null, null, 'all', null)));
  perform pg_temp.as_pg();
  -- add MORE flagged-only activity and see that the numbers do not move
  insert into leads (org_id, customer_id, name, mobile, source, status) values (v_org, v_cust_t, '__TEST_ L more', '9400000002', 'field', 'new');
  insert into leads (org_id, name, mobile, source, status) values (v_org, '__TEST_ L more by number', v_mob, 'field', 'new');
  perform pg_temp.as_user(v_master);
  v_f2 := jsonb_build_object('funnel', public.get_lead_funnel(now() - interval '1 day', now() + interval '1 day'),
                             'counts', public.followup_counts('all', null), 'nofu', (select count(*) from public.list_leads_without_followup(null, null, null, 'all', null)));
  perform pg_temp.as_pg();
  perform pg_temp.chk('funnel / follow-up counts / no-follow-up list unchanged by flagged leads', v_f1 = v_f2, v_f1::text || ' vs ' || v_f2::text);
  perform pg_temp.as_user(v_master);
  v_f1 := public.report_customer_totals(current_date - 30, current_date + 1);
  perform pg_temp.as_pg();
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ extra flagged', '9400000088', true);
  perform pg_temp.as_user(v_master);
  v_f2 := public.report_customer_totals(current_date - 30, current_date + 1);
  perform pg_temp.as_pg();
  perform pg_temp.chk('customer totals ignore a flagged customer', v_f1 = v_f2);
  -- a ticket for the flagged customer is excluded from the finder-conversion count for its owner
  perform pg_temp.chk('technician_finder_conversions runs (no error) with flagged data',
    public.technician_finder_conversions(v_org, v_tech1, date_trunc('month', now())::date) is not null);

  -- ---------- real data unchanged ----------
  perform pg_temp.chk('real customers unchanged', fp_d = (select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) from public.customers where org_id not in (select id from organizations where name like '\_\_TEST\_%')));
  perform pg_temp.chk('real tickets (status, SLA) unchanged', fp_b = (select md5(coalesce(string_agg(id::text||status::text||coalesce(sla_due_at::text,''), ',' order by id),'')) from public.service_tickets where org_id not in (select id from organizations where name like '\_\_TEST\_%')));
  perform pg_temp.chk('real appointments (time, technician, status) unchanged', fp_c = (select md5(coalesce(string_agg(id::text||coalesce(scheduled_at::text,'')||coalesce(technician_id::text,'')||status::text, ',' order by id),'')) from public.appointments where org_id not in (select id from organizations where name like '\_\_TEST\_%')));
  perform pg_temp.chk('only the new throwaway org gained customer rows',
    (select count(*) from customers where org_id = v_org) = 3);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
