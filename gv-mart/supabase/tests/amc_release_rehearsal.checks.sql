-- Rehearsal checks for 20261025100000_amc_release_unavailable_visits.sql. NOT RUN until the owner approves this text.
--
-- HOW IT IS USED: ONE request = the migration file, then this file, concatenated in that order (the migration is applied inside
-- the request's own transaction; nothing in either file begins, commits or savepoints). This file ends in an UNCONDITIONAL
-- RAISE EXCEPTION, so the request can never commit: everything the migration and the fixtures did vanishes with the rollback.
-- Everything the checks create is in a throwaway "__TEST_" organisation with unroutable 555 numbers; no real row is read for
-- writing. The DO block has no exception handlers: a failing statement aborts the request with its own error (still rolled
-- back); a failing CHECK is recorded as FAIL and the final RAISE prints every result.
create temp table res (n serial, line text);
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
-- an AMC visit as the sale leaves it: contract ticket 'assigned', one scheduled appointment with the technician
create function pg_temp.mkvisit(p_org uuid, p_customer uuid, p_contract uuid, p_prod uuid, p_no int, p_ts timestamptz, p_tech uuid)
returns uuid language plpgsql as $f$
declare v_t uuid; begin
  insert into public.service_tickets (org_id, customer_id, product_id, name_of_complaint, nature_of_complaint, type, priority, status, channel,
                                      contract_id, visit_no, assigned_at, sla_due_at)
  values (p_org, p_customer, p_prod, format('__TEST_ visit %s', p_no), '__TEST_ plan', 'amc', 'normal', 'assigned', 'call',
          p_contract, p_no, now(), now() + interval '48 hours')
  returning id into v_t;
  insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status, technician_id)
  values (p_org, v_t, 'datetime', p_ts, time '09:00', time '17:00', 'scheduled', p_tech);
  return v_t;
end $f$;

do $t$
declare
  v_org uuid; v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid; v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid;
  v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid; v_cust uuid; v_k uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_d_in date; v_d_far date; v_d_leave date; v_d_tick date;
  v_in uuid; v_far uuid; v_leave uuid; v_tick uuid; v_other uuid;
  v_out0 int; v_aud0 int; v_not0 int; v_r jsonb;
begin
  -- fixtures: a throwaway organisation, 4 technicians, one contract
  insert into organizations (name) values ('__TEST_amc_release_rehearsal') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_p1 := pg_temp.mkuser('technician', v_org); v_p2 := pg_temp.mkuser('technician', v_org);
  v_p3 := pg_temp.mkuser('technician', v_org); v_p4 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p1, true) returning id into v_t1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p2, true) returning id into v_t2;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p3, true) returning id into v_t3;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p4, true) returning id into v_t4;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ rehearsal', '5550900002') returning id into v_cust;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ plan', 3, 12000, 2) returning id into v_plan;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cust, v_prod, v_plan, v_today, v_today + interval '3 years', 'active') returning id into v_k;

  v_d_in    := public._visit_working_day(v_org, v_today + 3);
  v_d_leave := public._visit_working_day(v_org, v_today + 5);
  v_d_tick  := public._visit_working_day(v_org, v_today + 6);
  v_d_far   := public._visit_working_day(v_org, v_today + 30);

  -- visit 1 (in window) and 2 (beyond) are on technician 1; visit 3 is on technician 2; visit 4 on technician 4 (trigger off)
  v_in    := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 1, public._visit_start_ts(v_org, v_d_in),    v_t1);
  v_far   := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 2, public._visit_start_ts(v_org, v_d_far),   v_t1);
  v_leave := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 3, public._visit_start_ts(v_org, v_d_leave), v_t2);
  v_other := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 5, public._visit_start_ts(v_org, v_d_leave), v_t3);   -- same day, different technician, not on leave
  select count(*) into v_out0 from whatsapp_outbox where org_id = v_org;
  select count(*) into v_aud0 from audit_log where org_id = v_org and action = 'amc_visit_released';
  select count(*) into v_not0 from notifications where org_id = v_org and type = 'amc_visit_withdrawn';

  -- 1. the migration objects exist; the helper agrees with the engine's two reasons
  perform pg_temp.chk('0 release function, helper and both triggers exist',
    exists (select 1 from pg_proc where proname = 'release_unavailable_amc_visits' and pronamespace = 'public'::regnamespace)
    and exists (select 1 from pg_proc where proname = '_amc_visit_unavailable_reason' and pronamespace = 'public'::regnamespace)
    and exists (select 1 from pg_trigger where tgname = 'zz_amc_release_on_inactive' and not tgisinternal)
    and exists (select 1 from pg_trigger where tgname = 'zz_amc_release_on_leave' and not tgisinternal));
  perform pg_temp.chk('0 an active technician with no leave is not unavailable', public._amc_visit_unavailable_reason(v_t1, v_d_in) is null);

  -- 2. DEACTIVATION fires the trigger without blocking, releases in-window and beyond-window visits
  update technicians set is_active = false where id = v_t1;
  perform pg_temp.chk('1 deactivation was not blocked by the trigger', (select is_active = false from technicians where id = v_t1));
  perform pg_temp.chk('1 in-window visit: handed to another ACTIVE technician; ticket status stays assigned; new SLA set',
    (select a.technician_id is not null and a.technician_id <> v_t1 and t.status = 'assigned' and t.sla_due_at is not null
       from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_in),
    (select coalesce(a.technician_id::text, 'none') || ' ' || t.status from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_in));
  perform pg_temp.chk('1 in-window hand-over wrote NO new customer outbox row (no new milestone)',
    (select count(*) from whatsapp_outbox where org_id = v_org) = v_out0);
  perform pg_temp.chk('1 beyond-window visit: technician cleared, ticket open, assigned_at and sla_due_at cleared',
    (select a.technician_id is null and t.status = 'open' and t.assigned_at is null and t.sla_due_at is null
       from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_far));
  perform pg_temp.chk('1 the old technician was notified (2 notices, inactive reason)',
    (select count(*) from notifications where user_id = v_p1 and type = 'amc_visit_withdrawn' and is_read = false and body like '%no longer active%') = 2);
  perform pg_temp.chk('1 audit rows: 2 amc_visit_released, actor null, reason inactive',
    (select count(*) from audit_log where org_id = v_org and action = 'amc_visit_released' and actor_id is null and after ->> 'reason' = 'inactive') = 2);

  -- 3. LEAVE fires the trigger without blocking, releases that visit only
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t2, v_d_leave, 'leave');
  perform pg_temp.chk('2 the leave entry was not blocked by the trigger',
    exists (select 1 from technician_availability where technician_id = v_t2 and date = v_d_leave and status = 'leave'));
  perform pg_temp.chk('2 the visit on leave was released and handed to someone else',
    (select a.technician_id is not null and a.technician_id <> v_t2 and t.status = 'assigned' from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_leave));
  perform pg_temp.chk('2 technician 2 was notified (leave reason)',
    exists (select 1 from notifications where user_id = v_p2 and type = 'amc_visit_withdrawn' and body like '%on leave%'));
  perform pg_temp.chk('2 a visit of another technician on the same date was not touched',
    (select a.technician_id = v_t3 from appointments a where a.ticket_id = v_other));

  -- 4. IDEMPOTENT
  select count(*) into v_aud0 from audit_log where org_id = v_org and action = 'amc_visit_released';
  select count(*) into v_not0 from notifications where org_id = v_org and type = 'amc_visit_withdrawn';
  v_r := public.release_unavailable_amc_visits(now());
  perform pg_temp.chk('3 a second run releases nothing and writes no more audit or notification rows',
    (v_r ->> 'released')::int = 0 and (v_r ->> 'errors')::int = 0
    and (select count(*) from audit_log where org_id = v_org and action = 'amc_visit_released') = v_aud0
    and (select count(*) from notifications where org_id = v_org and type = 'amc_visit_withdrawn') = v_not0, v_r::text);

  -- 5. the daily tick: release and assign in separate blocks, ok heartbeat (visit found only because the trigger is off)
  alter table technicians disable trigger zz_amc_release_on_inactive;
  v_tick := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 4, public._visit_start_ts(v_org, v_d_tick), v_t4);
  update technicians set is_active = false where id = v_t4;
  alter table technicians enable trigger zz_amc_release_on_inactive;
  perform pg_temp.chk('4 with the trigger off the visit is still on the inactive technician', (select a.technician_id = v_t4 from appointments a where a.ticket_id = v_tick));
  perform public.amc_assign_cron_tick();
  perform pg_temp.chk('4 the daily tick released it and wrote an ok heartbeat',
    (select a.technician_id is distinct from v_t4 from appointments a where a.ticket_id = v_tick)
    and (select last_status = 'ok' and last_error is null from cron_job_heartbeats where job_key = 'amc_assign_due_visits'));

  -- 6. who can call what, and the throwaway-only guarantee
  perform pg_temp.chk('5 anon and authenticated cannot execute the release or the helper',
    not has_function_privilege('anon', 'public.release_unavailable_amc_visits(timestamptz,uuid,date)', 'execute')
    and not has_function_privilege('authenticated', 'public.release_unavailable_amc_visits(timestamptz,uuid,date)', 'execute')
    and not has_function_privilege('authenticated', 'public._amc_visit_unavailable_reason(uuid,date)', 'execute'));
  perform pg_temp.chk('6 no row of any real organisation was touched in this request',
    not exists (select 1 from public.service_tickets t join public.organizations o on o.id = t.org_id
                 where o.name not like '\_\_TEST\_%' and t.updated_at > now() - interval '5 minutes')
    and not exists (select 1 from public.audit_log al join public.organizations o on o.id = al.org_id
                     where o.name not like '\_\_TEST\_%' and al.action = 'amc_visit_released'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
