-- Rolled-back tests for 20261007120000_lead_followup_notifications.sql.
-- Run via the Management API (database/query); ends in a RAISE so nothing persists.
-- Time is simulated through run_lead_followup_notifications(p_now).
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

do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; v_ops uuid; v_tech uuid;
  la uuid; lb uuid; lc uuid; ld uuid; le uuid;
  r jsonb; n int; n_users int; rec record; b boolean; txt text;
  -- Tue 2026-10-06 (a working day)
  t_0900 timestamptz := '2026-10-06 03:30:00+00';  -- 09:00 IST
  t_0945 timestamptz := '2026-10-06 04:15:00+00';  -- 09:45 IST
  t_1510 timestamptz := '2026-10-06 09:40:00+00';  -- 15:10 IST
  t_1516 timestamptz := '2026-10-06 09:46:00+00';  -- 15:16 IST
  t_1520 timestamptz := '2026-10-06 09:50:00+00';  -- 15:20 IST
  t_1532 timestamptz := '2026-10-06 10:02:00+00';  -- 15:32 IST
  t_sun  timestamptz := '2026-10-11 04:30:00+00';  -- Sun 10:00 IST
  t_late timestamptz := '2026-10-06 14:30:00+00';  -- 20:00 IST (after close)
begin
  select org_id into v_org from profiles where role='master' limit 1;
  -- temporary users (rolled back with the test); the real demo accounts may be inactive or deleted
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tech := pg_temp.mkuser('technician', v_org);
  select count(*) into n_users from profiles where org_id=v_org and role in ('master','sales_admin') and is_active;
  delete from lead_notification_log;  -- rolled back; keeps the test independent of any real run
  -- Isolate from live data (all rolled back): a real cron run may already have sent today's digest, and the
  -- real open follow-ups would be counted into the digest. Only this test's own __N_ leads stay open.
  delete from notifications where type in ('lead_followup_digest','lead_followup_overdue','lead_callback_reminder');
  update lead_followups set status='cancelled', cancelled_at=now(), cancel_reason='rescheduled'
    where status='open' and lead_id in (select id from leads where org_id=v_org and name not like '\_\_N\_%');

  -- A: exact-time callback 15:30 IST; B: due today 11:00 IST; C: overdue 2 days; D: overdue 30h; E: overdue 5h (not stale)
  insert into leads(org_id,name,mobile) values (v_org,'__N_A_callback','9555555501') returning id into la;
  insert into leads(org_id,name,mobile) values (v_org,'__N_B_today','9555555502') returning id into lb;
  insert into leads(org_id,name,mobile) values (v_org,'__N_C_2days','9555555503') returning id into lc;
  insert into leads(org_id,name,mobile) values (v_org,'__N_D_30h','9555555504') returning id into ld;
  insert into leads(org_id,name,mobile) values (v_org,'__N_E_5h','9555555505') returning id into le;
  update lead_followups set due_at='2026-10-06 10:00:00+00', is_exact_time=true where lead_id=la and status='open';      -- 15:30 IST
  update lead_followups set due_at='2026-10-06 05:30:00+00' where lead_id=lb and status='open';                            -- 11:00 IST today
  update lead_followups set due_at='2026-10-04 05:30:00+00' where lead_id=lc and status='open';                            -- 2 days before
  update lead_followups set due_at='2026-10-04 22:15:00+00' where lead_id=ld and status='open';                            -- ~30h before 04:15Z (Oct 6 03:45 IST - ~... overdue >24h at 09:45 IST)
  update lead_followups set due_at='2026-10-05 23:15:00+00' where lead_id=le and status='open';                            -- 05:00 IST today -> < 5h before 09:45 IST? (Oct 6 04:45 IST) not >24h

  -- before opening: nothing
  r := run_lead_followup_notifications(t_0900);
  perform pg_temp.chk('09:00 IST (before opening): no digest, no stale list', (r->>'digests')::int=0 and (r->>'overdue_lists')::int=0 and (select count(*) from notifications where type in ('lead_followup_digest','lead_followup_overdue'))=0);

  -- 09:45 IST: digest + stale list once
  r := run_lead_followup_notifications(t_0945);
  perform pg_temp.chk('09:45 IST working day: digest sent', (r->>'digests')::int=1);
  select count(*) into n from notifications where type='lead_followup_digest' and user_id is not null;
  perform pg_temp.chk('digest goes to every active master + sales_admin (one row each)', n=n_users, 'rows='||n||' users='||n_users);
  select body into txt from notifications where type='lead_followup_digest' limit 1;
  perform pg_temp.chk('digest body counts today + overdue by IST day (B,E due today; A,... see body)', txt ~ '^[0-9]+ due today, [0-9]+ overdue', txt);
  perform pg_temp.chk('digest: today count = 3 (A 15:30, B 11:00, E 04:45 IST today) and overdue = 2 (C,D)', txt like '3 due today, 2 overdue%', txt);
  perform pg_temp.chk('stale list sent (>24h overdue)', (r->>'overdue_lists')::int=1);
  select body into txt from notifications where type='lead_followup_overdue' limit 1;
  perform pg_temp.chk('stale list names C and D only (older than 24h), not E or B', txt like '2 lead(s): %' and txt like '%__N_C_2days%' and txt like '%__N_D_30h%' and txt not like '%__N_E_5h%' and txt not like '%__N_B_today%', txt);
  r := run_lead_followup_notifications(t_0945);
  perform pg_temp.chk('same time again: no duplicate digest/stale list', (r->>'digests')::int=0 and (r->>'overdue_lists')::int=0 and (select count(*) from notifications where type='lead_followup_digest')=n_users);
  r := run_lead_followup_notifications(t_1510);
  perform pg_temp.chk('later the same day: still only one digest', (select count(*) from notifications where type='lead_followup_digest')=n_users);

  -- reminder window (15 minutes before an EXACT-time callback)
  perform pg_temp.chk('15:10 IST: callback at 15:30 is 20 min away -> no reminder yet', (select count(*) from notifications where type='lead_callback_reminder')=0);
  r := run_lead_followup_notifications(t_1516);
  perform pg_temp.chk('15:16 IST: callback at 15:30 within 15 min -> reminder sent to every recipient', (r->>'reminders')::int=1 and (select count(*) from notifications where type='lead_callback_reminder')=n_users);
  select title, body, ref_id into rec from notifications where type='lead_callback_reminder' limit 1;
  perform pg_temp.chk('reminder text has minutes, name, IST time and links the lead', rec.title like 'Callback in 14 min: __N_A_callback%' and rec.body like '%03:30 PM IST%' and rec.ref_id=la, rec.title||' / '||rec.body);
  r := run_lead_followup_notifications(t_1520);
  perform pg_temp.chk('reminder is not repeated on the next run', (r->>'reminders')::int=0 and (select count(*) from notifications where type='lead_callback_reminder')=n_users);
  update lead_followups set status='cancelled', cancelled_at=now(), cancel_reason='rescheduled' where lead_id=lb and status='open';
  perform pg_temp.chk('non-exact follow-ups never get a reminder (B was never reminded)', not exists (select 1 from notifications where type='lead_callback_reminder' and ref_id=lb));
  r := run_lead_followup_notifications(t_1532);
  perform pg_temp.chk('after the callback time: no reminder', (r->>'reminders')::int=0);

  -- Sunday + after hours
  delete from lead_notification_log where kind in ('digest','overdue24');
  delete from notifications where type in ('lead_followup_digest','lead_followup_overdue');
  r := run_lead_followup_notifications(t_sun);
  perform pg_temp.chk('Sunday (non-working day): no digest', (r->>'digests')::int=0 and (select count(*) from notifications where type='lead_followup_digest')=0);
  r := run_lead_followup_notifications(t_late);
  perform pg_temp.chk('20:00 IST (after close): no digest', (r->>'digests')::int=0);

  -- visibility
  perform pg_temp.chk('seed row for visibility test', true);
  delete from lead_notification_log where kind='digest';
  perform run_lead_followup_notifications(t_0945);
  for rec in select * from (values ('master',v_master),('sales_admin',v_sales),('operation_admin',v_ops),('technician',v_tech)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    select count(*) into n from notifications where type='lead_followup_digest';
    perform pg_temp.chk('digest visibility for '||rec.role||' (master sees the whole org by existing policy, sales_admin only its own row, others none)', case when rec.role='master' then n=n_users when rec.role='sales_admin' then n=1 else n=0 end, 'rows='||n);
    begin perform run_lead_followup_notifications(); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('runner not callable by '||rec.role, b=false);
    perform pg_temp.as_pg();
  end loop;

  -- mirror new-lead notifications to master
  delete from notifications where type in ('enquiry_lead','callback_requested','wa_lead_captured','other_test');
  insert into notifications(org_id, role, type, title, body) values (v_org,'sales_admin','enquiry_lead','New product enquiry','x');
  insert into notifications(org_id, role, type, title, body) values (v_org,'sales_admin','callback_requested','Callback requested','x');
  insert into notifications(org_id, role, type, title, body) values (v_org,'sales_admin','wa_lead_captured','New WhatsApp lead','x');
  insert into notifications(org_id, role, type, title, body) values (v_org,'sales_admin','other_test','not a lead notification','x');
  perform pg_temp.chk('3 new-lead notification types are mirrored to master (once each)',
    (select count(*) from notifications where role='master' and type in ('enquiry_lead','callback_requested','wa_lead_captured'))=3
    and (select count(*) from notifications where role='sales_admin' and type in ('enquiry_lead','callback_requested','wa_lead_captured'))=3);
  perform pg_temp.chk('other sales_admin notification types are NOT mirrored', (select count(*) from notifications where role='master' and type='other_test')=0);
  perform pg_temp.as_user(v_master);
  select count(*) into n from notifications where role='master' and type='enquiry_lead';
  perform pg_temp.chk('master can read the mirrored notification', n=1);
  perform pg_temp.as_pg();

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
