-- NOTE (No follow-up migration 20261008160000): the digest now also reports open leads WITHOUT a follow-up, and the real
-- organisation has such leads, so its rows are no longer compared; the throwaway organisation (all leads scheduled) must stay identical.
-- Rolled-back PARITY test for Phase 2 gap 3 (migration 20261008130000_lead_assignment).
-- Runs the OLD run_lead_followup_notifications (its source from migration 20261007120000, created as a
-- pg_temp function) and then the NEW public one at the same simulated times. Both runners loop over every
-- organisation, so rows for the real organisation are compared too (old must equal new whatever it holds,
-- including nothing), but NO assertion depends on live data: every expectation is about
--   a throwaway organisation with a master + a sales_admin and __TEST_ leads that exercise
--       digest, overdue-24h and exact-time reminders,
-- and compares every notification row they create. Everything ends in a RAISE (rolled back).
-- The old function runs against the real organisation INSIDE the transaction only; the rows it writes
-- are removed again before the new function runs and the transaction is rolled back at the end.
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


-- ===== the OLD runner, verbatim from migration 20261007120000 =====
create or replace function pg_temp.old_run_lead_followup_notifications(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org record;
  v_s record;
  v_today date := public._lead_ist_date(p_now);
  v_time time := (p_now at time zone 'Asia/Kolkata')::time;
  v_start time;
  v_end time;
  v_reminder integer;
  v_n_today integer;
  v_n_overdue integer;
  v_n_stale integer;
  v_names text;
  v_f record;
  v_digests integer := 0;
  v_reminders integer := 0;
  v_stale_sent integer := 0;
  v_key text;
begin
  for v_org in select id from public.organizations loop
    select * into v_s from public.settings where org_id = v_org.id;
    v_start := coalesce(v_s.lead_work_start, '09:30');
    v_end := coalesce(v_s.lead_work_end, '19:00');
    v_reminder := coalesce(v_s.lead_reminder_minutes, 15);

    -- Digest + stale list: once per working day, from opening time until closing.
    if public._lead_is_working_day(v_org.id, v_today) and v_time >= v_start and v_time <= v_end then
      v_key := v_org.id::text || ':' || v_today::text;

      -- 1. digest
      if not exists (select 1 from public.lead_notification_log where kind = 'digest' and key = v_key) then
        select
          count(*) filter (where public._lead_ist_date(f.due_at) = v_today),
          count(*) filter (where public._lead_ist_date(f.due_at) < v_today)
        into v_n_today, v_n_overdue
        from public.lead_followups f join public.leads l on l.id = f.lead_id
        where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost');

        insert into public.lead_notification_log (kind, key) values ('digest', v_key);
        if v_n_today + v_n_overdue > 0 then
          insert into public.notifications (org_id, user_id, type, title, body)
          select v_org.id, p.id, 'lead_followup_digest', 'Follow-ups for today',
                 format('%s due today, %s overdue. Open My Day.', v_n_today, v_n_overdue)
          from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
          v_digests := v_digests + 1;
        end if;
      end if;

      -- 3. overdue more than 24 hours
      if not exists (select 1 from public.lead_notification_log where kind = 'overdue24' and key = v_key) then
        select count(*), string_agg(name, ', ' order by due_at)
        into v_n_stale, v_names
        from (
          select coalesce(c.name, l.name) as name, f.due_at
          from public.lead_followups f join public.leads l on l.id = f.lead_id
          left join public.customers c on c.id = l.customer_id
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
            and f.due_at < p_now - interval '24 hours'
          order by f.due_at limit 5
        ) s;
        select count(*) into v_n_stale
        from public.lead_followups f join public.leads l on l.id = f.lead_id
        where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost')
          and f.due_at < p_now - interval '24 hours';

        insert into public.lead_notification_log (kind, key) values ('overdue24', v_key);
        if v_n_stale > 0 then
          insert into public.notifications (org_id, user_id, type, title, body)
          select v_org.id, p.id, 'lead_followup_overdue', 'Follow-ups overdue by more than 24 hours',
                 format('%s lead(s): %s%s', v_n_stale, v_names, case when v_n_stale > 5 then ' …' else '' end)
          from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
          v_stale_sent := v_stale_sent + 1;
        end if;
      end if;
    end if;

    -- 2. exact-time callback reminders (any day: staff may agree a Sunday call)
    for v_f in
      select f.id, f.due_at, l.id as lead_id, coalesce(c.name, l.name) as name, coalesce(l.mobile, c.mobile) as mobile
      from public.lead_followups f
      join public.leads l on l.id = f.lead_id
      left join public.customers c on c.id = l.customer_id
      where f.org_id = v_org.id and f.status = 'open' and f.is_exact_time and l.status not in ('won', 'lost')
        and f.due_at >= p_now and f.due_at <= p_now + make_interval(mins => v_reminder)
        and not exists (select 1 from public.lead_notification_log g where g.kind = 'reminder' and g.key = f.id::text)
    loop
      insert into public.lead_notification_log (kind, key) values ('reminder', v_f.id::text);
      insert into public.notifications (org_id, user_id, type, title, body, ref_id)
      select v_org.id, p.id, 'lead_callback_reminder',
             format('Callback in %s min: %s', greatest(1, ceil(extract(epoch from (v_f.due_at - p_now)) / 60)::int), v_f.name),
             format('%s%s at %s IST', v_f.name, coalesce(' (' || v_f.mobile || ')', ''), to_char(v_f.due_at at time zone 'Asia/Kolkata', 'HH12:MI AM')),
             v_f.lead_id
      from public.profiles p
      where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active;
      v_reminders := v_reminders + 1;
    end loop;
  end loop;

  return jsonb_build_object('digests', v_digests, 'reminders', v_reminders, 'overdue_lists', v_stale_sent, 'ran_at', p_now);
end;
$$;

create temp table ctx (k text primary key, v text);
create temp table cap (phase text, scenario text, org_id uuid, user_id uuid, type text, title text, body text, ref_id uuid);
create temp table ret (phase text, scenario text, rj jsonb);
grant all on ctx, cap, ret to public;

do $setup$
declare v_real uuid; v_t uuid; v_m uuid; v_s uuid; l uuid;
begin
  select id into v_real from organizations where name not like '\_\_TEST\_%' order by created_at limit 1;
  insert into organizations (name) values ('__TEST_parity_org') returning id into v_t;
  v_m := pg_temp.mkuser('master', v_t);
  v_s := pg_temp.mkuser('sales_admin', v_t);
  insert into ctx values ('real', v_real::text), ('test', v_t::text), ('master', v_m::text), ('sales', v_s::text);
  -- A: exact-time callback 14:30 IST on Wed 14 Oct; B: overdue 2 days; C: due today; D: overdue 30h; E: due today, 2nd lead
  insert into leads(org_id,name,mobile) values (v_t,'__TEST_A_callback','9777777701') returning id into l; update lead_followups set due_at='2026-10-14 09:00:00+00', is_exact_time=true where lead_id=l and status='open';
  insert into leads(org_id,name,mobile) values (v_t,'__TEST_B_2days','9777777702') returning id into l; update lead_followups set due_at='2026-10-12 05:30:00+00' where lead_id=l and status='open';
  insert into leads(org_id,name,mobile) values (v_t,'__TEST_C_today','9777777703') returning id into l; update lead_followups set due_at='2026-10-14 05:30:00+00' where lead_id=l and status='open';
  insert into leads(org_id,name,mobile) values (v_t,'__TEST_D_30h','9777777704') returning id into l; update lead_followups set due_at='2026-10-13 00:30:00+00' where lead_id=l and status='open';
  insert into leads(org_id,name,mobile) values (v_t,'__TEST_E_today','9777777705') returning id into l; update lead_followups set due_at='2026-10-14 11:00:00+00' where lead_id=l and status='open';
  -- remove anything the setup itself created so only the runner's output is captured
  delete from notifications where created_at = now();
  delete from lead_notification_log where created_at = now();
end $setup$;

-- ===== BEFORE: the old runner =====
do $old$
declare r jsonb; sc text; t timestamptz;
begin
  for sc, t in select * from (values ('s1 Wed 10:00 IST','2026-10-14 04:30:00+00'::timestamptz), ('s2 same day again','2026-10-14 04:35:00+00'), ('s3 reminder window','2026-10-14 08:50:00+00'), ('s4 Sunday','2026-10-18 04:30:00+00'), ('s5 Thu 10:00 IST','2026-10-15 04:30:00+00')) x loop
    r := pg_temp.old_run_lead_followup_notifications(t);
    insert into ret values ('old', sc, r - 'ran_at');
    insert into cap select 'old', sc, org_id, user_id, type, title, body, ref_id from notifications where created_at = now() and type like 'lead\_%' and not exists (select 1 from cap c2 where false);
    delete from notifications where created_at = now();
  end loop;
  delete from lead_notification_log where created_at = now();
end $old$;

-- ===== AFTER: the new runner (same scenarios, no org filter = same all-org behaviour) =====
do $new$
declare r jsonb; sc text; t timestamptz; txt text; n_old int; n_new int; real_org uuid; test_org uuid; ok boolean;
  m uuid; s uuid; d_old text; d_new text; rec record;
begin
  select v::uuid into real_org from ctx where k='real'; select v::uuid into test_org from ctx where k='test';
  select v::uuid into m from ctx where k='master'; select v::uuid into s from ctx where k='sales';
  for sc, t in select * from (values ('s1 Wed 10:00 IST','2026-10-14 04:30:00+00'::timestamptz), ('s2 same day again','2026-10-14 04:35:00+00'), ('s3 reminder window','2026-10-14 08:50:00+00'), ('s4 Sunday','2026-10-18 04:30:00+00'), ('s5 Thu 10:00 IST','2026-10-15 04:30:00+00')) x loop
    r := public.run_lead_followup_notifications(t);
    insert into ret values ('new', sc, r - 'ran_at');
    insert into cap select 'new', sc, org_id, user_id, type, title, body, ref_id from notifications where created_at = now() and type like 'lead\_%';
    delete from notifications where created_at = now();
  end loop;

  for rec in select distinct scenario from ret order by 1 loop
    select md5(coalesce(string_agg(org_id::text||'|'||user_id::text||'|'||type||'|'||title||'|'||body||'|'||coalesce(ref_id::text,''), E'\n' order by org_id::text,user_id::text,type,title,body), '')), count(*) into d_old, n_old from cap where phase='old' and scenario=rec.scenario and org_id = test_org;
    select md5(coalesce(string_agg(org_id::text||'|'||user_id::text||'|'||type||'|'||title||'|'||body||'|'||coalesce(ref_id::text,''), E'\n' order by org_id::text,user_id::text,type,title,body), '')), count(*) into d_new, n_new from cap where phase='new' and scenario=rec.scenario and org_id = test_org;
    perform pg_temp.chk('notification rows identical (every org, user, type, title, body, ref): ' || rec.scenario, d_old = d_new and n_old = n_new, n_old || ' rows old / ' || n_new || ' new');
  end loop;

  perform pg_temp.chk('throwaway organisation: master + sales_admin each got digest, overdue list', (select count(*) from cap where phase='new' and scenario='s1 Wed 10:00 IST' and org_id=test_org and type in ('lead_followup_digest','lead_followup_overdue'))=4);
  perform pg_temp.chk('throwaway organisation: reminder sent to both recipients in s3', (select count(*) from cap where phase='new' and scenario='s3 reminder window' and org_id=test_org and type='lead_callback_reminder')=2);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $new$;
