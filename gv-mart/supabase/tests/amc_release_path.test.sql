-- Rolled-back DB test for 20261024100000_amc_release_unavailable_visits.sql (AMC visit release path).
-- NOT RUN: written with the migration for review; run it only on explicit approval.
-- Runner: BEGIN; the migration (already applied live, then nothing to prepend); this file as its OWN transaction. It ends in
-- RAISE EXCEPTION 'RESULTS...', so it can never commit. Never concatenate it with the migration file. A throwaway __TEST_
-- organisation with unroutable 555 numbers is created inside the transaction and vanishes with the rollback; nothing is sent.
-- Fixture visits are inserted directly in the "assigned at sale" shape (ticket assigned, appointment scheduled with a technician),
-- on working days that are in the future so no attendance check-in is needed.
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
-- an AMC visit as the sale leaves it: contract ticket, assigned, one scheduled appointment with the technician
create function pg_temp.mkvisit(p_org uuid, p_customer uuid, p_contract uuid, p_prod uuid, p_no int, p_ts timestamptz,
                                p_tech uuid, p_type text default 'amc', p_tstatus text default 'assigned', p_astatus text default 'scheduled')
returns uuid language plpgsql as $f$
declare v_t uuid; begin
  insert into public.service_tickets (org_id, customer_id, product_id, name_of_complaint, nature_of_complaint, type, priority, status, channel,
                                      contract_id, visit_no, assigned_at, sla_due_at)
  values (p_org, p_customer, p_prod, format('__TEST_ visit %s', p_no), '__TEST_ plan', p_type::public.ticket_type, 'normal', p_tstatus::public.ticket_status, 'call',
          case when p_type = 'amc' then p_contract end, case when p_type = 'amc' then p_no end,
          case when p_tstatus = 'assigned' then now() end, case when p_tstatus = 'assigned' then now() + interval '48 hours' end)
  returning id into v_t;
  insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status, technician_id)
  values (p_org, v_t, 'datetime', p_ts, time '09:00', time '17:00', p_astatus::public.appointment_status, p_tech);
  return v_t;
end $f$;

do $t$
declare
  v_org uuid; v_master uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid; v_p5 uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid;
  v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid; v_cust uuid; v_k uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_d1 date; v_d2 date; v_d3 date; v_d4 date; v_d5 date; v_d6 date; v_d7 date; v_far date;
  v_tk1 uuid; v_tk2 uuid; v_tk3 uuid; v_tk_far uuid; v_tk_prog uuid; v_tk_done uuid; v_tk_paid uuid; v_tk_past uuid; v_tk_other uuid; v_tk_leaveother uuid; v_tk_none uuid;
  v_r jsonb; n int; n2 int; v_aud int; v_notif int; s text;
begin
  -- ---------- throwaway organisation: 5 technicians, one master, one contract ----------
  insert into organizations (name) values ('__TEST_amc_release') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_p1 := pg_temp.mkuser('technician', v_org); v_p2 := pg_temp.mkuser('technician', v_org); v_p3 := pg_temp.mkuser('technician', v_org);
  v_p4 := pg_temp.mkuser('technician', v_org); v_p5 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p1, true) returning id into v_t1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p2, true) returning id into v_t2;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p3, true) returning id into v_t3;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p4, true) returning id into v_t4;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p5, true) returning id into v_t5;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ release', '5550900001') returning id into v_cust;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ plan', 3, 12000, 2) returning id into v_plan;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_cust, v_prod, v_plan, v_today, v_today + interval '3 years', 'active') returning id into v_k;

  v_d1 := public._visit_working_day(v_org, v_today + 2);
  v_d2 := public._visit_working_day(v_org, v_today + 3);
  v_d3 := public._visit_working_day(v_org, v_today + 4);
  v_d4 := public._visit_working_day(v_org, v_today + 5);
  v_d5 := public._visit_working_day(v_org, v_today + 6);
  v_d6 := public._visit_working_day(v_org, v_today + 1);
  v_d7 := public._visit_working_day(v_org, v_today + 12);
  v_far := public._visit_working_day(v_org, v_today + 30);

  -- ---------- A. the helper: one definition of "unavailable" ----------
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t3, v_d3, 'working');
  perform pg_temp.chk('A active technician, no leave: not unavailable', public._amc_visit_unavailable_reason(v_t1, v_d1) is null);
  perform pg_temp.chk('A a "working" availability row is not leave', public._amc_visit_unavailable_reason(v_t3, v_d3) is null);
  delete from technician_availability where technician_id = v_t3 and date = v_d3;

  -- ---------- B. fixtures, all assigned to technician 1 (in window, beyond window) ----------
  v_tk1  := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 1, public._visit_start_ts(v_org, v_d1), v_t1);
  v_tk_far := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 2, public._visit_start_ts(v_org, v_far), v_t1);
  -- never touched: in progress, completed, cancelled, a paid service ticket, a visit already in the past
  v_tk_prog := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 3, public._visit_start_ts(v_org, v_d2), v_t1, 'amc', 'in_progress', 'in_progress');
  v_tk_done := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 4, public._visit_start_ts(v_org, v_d3), v_t1, 'amc', 'completed', 'completed');
  v_tk_paid := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 5, public._visit_start_ts(v_org, v_d4), v_t1, 'paid', 'assigned', 'scheduled');
  v_tk_past := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 6, now() - interval '2 days', v_t1);
  -- an unassigned open visit
  v_tk_none := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 7, public._visit_start_ts(v_org, v_d5), null, 'amc', 'open', 'scheduled');
  -- technician 3 has a visit on d6 and leave on a DIFFERENT date (d7)
  v_tk_leaveother := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 8, public._visit_start_ts(v_org, v_d6), v_t3);
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t3, v_d7, 'leave');
  perform pg_temp.chk('B fixtures: a leave row on another date does not release technician 3''s visit',
    (select a.technician_id = v_t3 from appointments a where a.ticket_id = v_tk_leaveother)
    and not exists (select 1 from notifications where user_id = v_p3 and type = 'amc_visit_withdrawn'));

  -- ---------- C. deactivation releases at once (trigger), reassigns inside the window, reopens beyond it ----------
  perform pg_temp.chk('C before: visit and far visit are on technician 1', (select count(*) from appointments where technician_id = v_t1 and ticket_id in (v_tk1, v_tk_far)) = 2);
  update technicians set is_active = false where id = v_t1;
  perform pg_temp.chk('C the deactivation itself succeeded (the trigger never blocks it)', (select is_active = false from technicians where id = v_t1));
  perform pg_temp.chk('C in-window visit was handed to another ACTIVE technician; ticket is assigned with a new SLA, not technician 1',
    (select a.technician_id is not null and a.technician_id <> v_t1 and t.status = 'assigned' and t.sla_due_at is not null
       from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk1),
    (select coalesce(a.technician_id::text, 'none') || ' ' || t.status from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk1));
  perform pg_temp.chk('C beyond-window visit: technician cleared, ticket back to open, assigned_at and sla_due_at cleared',
    (select a.technician_id is null and t.status = 'open' and t.assigned_at is null and t.sla_due_at is null
       from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk_far));
  perform pg_temp.chk('C technician 1 was TOLD: one withdrawal notice per released visit, naming the reason',
    (select count(*) from notifications where user_id = v_p1 and type = 'amc_visit_withdrawn') = 2
    and exists (select 1 from notifications where user_id = v_p1 and type = 'amc_visit_withdrawn' and body like '%no longer active%'));
  perform pg_temp.chk('C an audit row was written for each release: action amc_visit_released, actor null, reason inactive',
    (select count(*) from audit_log where org_id = v_org and action = 'amc_visit_released' and actor_id is null and after ->> 'reason' = 'inactive') = 2);
  perform pg_temp.chk('C the new technician got the normal assignment notice',
    exists (select 1 from notifications n join appointments a on a.id = n.ref_id where a.ticket_id = v_tk1 and n.type = 'appointment_assigned' and n.user_id <> v_p1));
  perform pg_temp.chk('C a hand-over inside the window sent the customer nothing new (no outbox row for the visit ticket)',
    not exists (select 1 from whatsapp_outbox where ref_id in (v_tk1, v_tk_far)));

  -- ---------- D. things that must never be touched ----------
  perform pg_temp.chk('D in-progress visit left on technician 1', (select a.technician_id = v_t1 and a.status = 'in_progress' from appointments a where a.ticket_id = v_tk_prog));
  perform pg_temp.chk('D completed visit left alone', (select a.technician_id = v_t1 and a.status = 'completed' from appointments a where a.ticket_id = v_tk_done));
  perform pg_temp.chk('D a non-AMC (paid) ticket on an inactive technician is not released here',
    (select a.technician_id = v_t1 and t.status = 'assigned' from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk_paid));
  perform pg_temp.chk('D a visit already in the past is left for staff, not silently re-assigned',
    (select a.technician_id = v_t1 from appointments a where a.ticket_id = v_tk_past));
  perform pg_temp.chk('D an already-unassigned open visit is untouched (no notice)',
    (select a.technician_id is null and t.status = 'open' from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk_none));

  -- ---------- E. leave releases that visit only, on that date ----------
  -- technician 2 may have been given the d1 visit above; give it a deliberate visit instead of relying on that
  v_tk_other := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 9, public._visit_start_ts(v_org, v_d4 + 7), v_t2);
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t2, (v_d4 + 7), 'leave');
  perform pg_temp.chk('E leave on the visit date released it; reassigned to someone else on duty',
    (select a.technician_id is not null and a.technician_id <> v_t2 from appointments a where a.ticket_id = v_tk_other));
  perform pg_temp.chk('E technician 2 got the withdrawal notice with the leave reason',
    exists (select 1 from notifications where user_id = v_p2 and type = 'amc_visit_withdrawn' and body like '%on leave%'));

  -- ---------- F. idempotent; the daily function and the cron tick ----------
  select count(*) into n from audit_log where org_id = v_org and action = 'amc_visit_released';
  select count(*) into n2 from notifications where org_id = v_org and type = 'amc_visit_withdrawn';
  v_r := public.release_unavailable_amc_visits(now());
  perform pg_temp.chk('F second run releases nothing and writes nothing more',
    (v_r ->> 'released')::int = 0 and (v_r ->> 'errors')::int = 0
    and (select count(*) from audit_log where org_id = v_org and action = 'amc_visit_released') = n
    and (select count(*) from notifications where org_id = v_org and type = 'amc_visit_withdrawn') = n2, v_r::text);

  -- a visit whose technician became inactive while the trigger was off: only the daily run can find it
  alter table technicians disable trigger zz_amc_release_on_inactive;
  v_tk_none := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 10, public._visit_start_ts(v_org, public._visit_working_day(v_org, v_today + 8)), v_t4);
  update technicians set is_active = false where id = v_t4;
  alter table technicians enable trigger zz_amc_release_on_inactive;
  perform pg_temp.chk('F with the trigger off the visit is still on the inactive technician',
    (select a.technician_id = v_t4 from appointments a where a.ticket_id = v_tk_none));
  perform public.amc_assign_cron_tick();
  perform pg_temp.chk('F the daily tick released it (release runs before assign) and wrote an ok heartbeat',
    (select a.technician_id is distinct from v_t4 from appointments a where a.ticket_id = v_tk_none)
    and (select last_status = 'ok' from cron_job_heartbeats where job_key = 'amc_assign_due_visits'));

  -- ---------- G. nobody free: reopened, ONE alert ----------
  update technicians set is_active = false where id = v_t2;
  update technicians set is_active = false where id = v_t3;
  v_tk_none := pg_temp.mkvisit(v_org, v_cust, v_k, v_prod, 11, public._visit_start_ts(v_org, public._visit_working_day(v_org, v_today + 9)), v_t5);
  insert into technician_availability (org_id, technician_id, date, status)
  values (v_org, v_t5, public._visit_working_day(v_org, v_today + 9), 'leave');
  perform pg_temp.chk('G nobody on duty: ticket back to open and unassigned',
    (select a.technician_id is null and t.status = 'open' from appointments a join service_tickets t on t.id = a.ticket_id where a.ticket_id = v_tk_none));
  perform pg_temp.chk('G exactly ONE unread "needs manual assignment" alert for it',
    (select count(*) from notifications where ref_id = v_tk_none and type = 'ticket_unassigned' and is_read = false) = 1);
  v_r := public.release_unavailable_amc_visits(now());
  perform pg_temp.chk('G a further run does not add a second alert',
    (select count(*) from notifications where ref_id = v_tk_none and type = 'ticket_unassigned' and is_read = false) = 1);

  -- ---------- H. who can call what ----------
  perform pg_temp.chk('H anon and authenticated cannot execute the release, the helper or the trigger functions',
    not has_function_privilege('anon', 'public.release_unavailable_amc_visits(timestamptz,uuid,date)', 'execute')
    and not has_function_privilege('authenticated', 'public.release_unavailable_amc_visits(timestamptz,uuid,date)', 'execute')
    and not has_function_privilege('authenticated', 'public._amc_visit_unavailable_reason(uuid,date)', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_amc_release_on_leave()', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_amc_release_on_technician_inactive()', 'execute')
    and has_function_privilege('service_role', 'public.release_unavailable_amc_visits(timestamptz,uuid,date)', 'execute'));
  perform pg_temp.chk('H the cron jobs are unchanged (still the two AMC jobs, same commands)',
    (select count(*) from cron.job where jobname in ('amc-assign-due-visits', 'amc-assign-deadman')) = 2
    and exists (select 1 from cron.job where jobname = 'amc-assign-due-visits' and command = 'select public.amc_assign_cron_tick()'));

  -- ---------- I. real data untouched ----------
  perform pg_temp.chk('I no real organisation row was touched',
    not exists (select 1 from public.service_tickets t join public.organizations o on o.id = t.org_id
                 where o.name not like '\_\_TEST\_%' and t.updated_at > now() - interval '5 minutes'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
