-- Rolled-back DB tests for migration 20261012130000_digest_daily_follow_up_name (batch-17 item 5, digest text).
-- One transaction ending in RAISE; read RESULTS in the error. Throwaway __TEST_ organisation created inside the transaction.
-- run_lead_followup_notifications is called for that org only (p_org_id), at a fixed working-day time, so no real
-- organisation, lead or notification is touched.
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

do $t$
declare
  v_org uuid; v_master uuid; txt text; r jsonb; v_body text; l1 uuid; l2 uuid;
  v_now timestamptz := timestamptz '2026-10-13 11:00:00+05:30';   -- a Tuesday, inside working hours IST
begin
  insert into organizations (name) values ('__TEST_b17_digest') returning id into v_org;
  update settings set lead_work_days = array[1,2,3,4,5,6], lead_work_start = '09:30', lead_work_end = '19:00' where org_id = v_org;
  v_master := pg_temp.mkuser('master', v_org);
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_d1','9300000001') returning id into l1;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_d2','9300000002') returning id into l2;
  -- l1: open follow-up due that day; l2: no open follow-up
  update lead_followups set due_at = timestamptz '2026-10-13 15:00:00+05:30' where lead_id = l1 and status='open';
  update lead_followups set status='cancelled', cancelled_at=now(), cancel_reason='test' where lead_id = l2 and status='open';

  perform pg_temp.chk('the digest function still has one signature', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='run_lead_followup_notifications')=1);
  perform pg_temp.chk('digest function ACL unchanged: no anon, no authenticated',
    not has_function_privilege('anon','public.run_lead_followup_notifications(timestamptz,uuid)','execute')
    and not has_function_privilege('authenticated','public.run_lead_followup_notifications(timestamptz,uuid)','execute'));

  r := run_lead_followup_notifications(v_now, v_org);
  perform pg_temp.chk('a digest was sent for the test org', (r->>'digests')::int = 1, r::text);
  select n.body into v_body from notifications n where n.org_id = v_org and n.user_id = v_master and n.type = 'lead_followup_digest';
  perform pg_temp.chk('digest body says Daily Follow Up', v_body like '%Open Daily Follow Up.%', v_body);
  perform pg_temp.chk('digest body no longer says My Day', v_body not ilike '%my day%', v_body);
  perform pg_temp.chk('digest body still carries the due-today / overdue counts', v_body like '1 due today, 0 overdue.%', v_body);
  perform pg_temp.chk('digest body still carries the no-follow-up sentence', v_body like '%1 lead(s) have no follow-up.%', v_body);
  perform pg_temp.chk('digest title unchanged', (select title from notifications where org_id = v_org and user_id = v_master and type = 'lead_followup_digest') = 'Follow-ups for today');

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
