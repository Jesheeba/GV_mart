-- Rolled-back DB tests for 'No follow-up' (migration 20261008160000), run against the LIVE functions.
-- This file used to re-create the migration's function definitions inside the transaction. That went stale: it re-created
-- list_leads_without_followup(.., lead_kind, ..) next to the live text-kind version (20261012100000) and made every call
-- ambiguous, and it would silently re-install older bodies of set_lead_followup / the digest. It now tests what is deployed.
-- Everything runs in a throwaway __T organisation inside one transaction that ends in a RAISE; read RESULTS in the error.
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
  v_org uuid; m uuid; s1 uuid; s2 uuid; s3 uuid; ops uuid; tech uuid; cust uuid;
  a uuid; b uuid; c uuid; d uuid; e uuid; closed uuid; sch uuid;
  l uuid[]; r jsonb; txt text; ok boolean; n int; rec record; v_body text; ids uuid[];
  due_c timestamptz; thu date; f_id uuid; g_id uuid;
begin
  -- a Thursday at least 14 days ahead (IST), so the Thu/Fri/Sat/Mon expectations hold on any run date
  thu := (now() at time zone 'Asia/Kolkata')::date + 14;
  while extract(isodow from thu) <> 4 loop thu := thu + 1; end loop;
  due_c := (thu::text || ' 10:00:00+05:30')::timestamptz;
  insert into organizations (name) values ('__TEST_nofu_org') returning id into v_org;
  m := pg_temp.mkuser('master', v_org); s1 := pg_temp.mkuser('sales_admin', v_org); s2 := pg_temp.mkuser('sales_admin', v_org);
  s3 := pg_temp.mkuser('sales_admin', v_org); ops := pg_temp.mkuser('operation_admin', v_org); tech := pg_temp.mkuser('technician', v_org); cust := pg_temp.mkuser('customer', v_org);
  update profiles set is_active = false where id = s3;

  -- five open leads (oldest first a..e), one scheduled lead, one closed lead. Remove the automatic Initial calls so they lack follow-ups.
  insert into leads(org_id,name,mobile,source,kind) values (v_org,'__TEST_a','9666666601','other','service') returning id into a;
  insert into leads(org_id,name,mobile,source,kind) values (v_org,'__TEST_b','9666666602','other','spare') returning id into b;
  insert into leads(org_id,name,mobile,source,kind) values (v_org,'__TEST_c','9666666603','other','service') returning id into c;
  insert into leads(org_id,name,mobile,source,kind) values (v_org,'__TEST_d','9666666604','other','service') returning id into d;
  insert into leads(org_id,name,mobile,source,kind) values (v_org,'__TEST_e','9666666605','other','service') returning id into e;
  insert into leads(org_id,name,mobile,status) values (v_org,'__TEST_closed','9666666606','lost') returning id into closed;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_sched','9666666607') returning id into sch;
  update leads set created_at = now() - interval '5 days' where id = a;
  update leads set created_at = now() - interval '4 days' where id = b;
  update leads set created_at = now() - interval '3 days' where id = c;
  update leads set created_at = now() - interval '2 days' where id = d;
  update leads set created_at = now() - interval '1 day' where id = e;
  update leads set status = 'contacted' where id = d;
  delete from lead_followups where lead_id <> sch and org_id = v_org;
  perform pg_temp.as_user(m); perform assign_lead(c, s2); perform assign_lead(e, s1); perform pg_temp.as_pg();   -- a,b,d unassigned; c -> s2; e -> s1
  perform pg_temp.chk('setup: 5 open leads without a follow-up, 1 scheduled', (select count(*) from leads l where org_id = v_org and status <> 'lost' and not exists (select 1 from lead_followups f where f.lead_id = l.id and f.status = 'open')) = 5);

  -- ===== list_leads_without_followup =====
  perform pg_temp.as_user(m);
  perform pg_temp.chk('master auto scope: all 5, oldest first, scheduled and closed leads excluded',
    (select array_agg(lead_name order by created_at) from list_leads_without_followup()) = array['__TEST_a','__TEST_b','__TEST_c','__TEST_d','__TEST_e']);
  perform pg_temp.chk('assignee names returned', (select assignee_name from list_leads_without_followup() where lead_name = '__TEST_c') = '__T sales_admin');
  perform pg_temp.chk('stage filter', (select array_agg(lead_name) from list_leads_without_followup(p_stage => 'contacted')) = array['__TEST_d']);
  perform pg_temp.chk('kind filter', (select array_agg(lead_name) from list_leads_without_followup(p_kind => 'spare')) = array['__TEST_b']);
  perform pg_temp.chk('person scope (master)', (select array_agg(lead_name) from list_leads_without_followup(p_scope => 'person', p_assignee => s2)) = array['__TEST_c']);
  perform pg_temp.chk('unassigned scope', (select count(*) from list_leads_without_followup(p_scope => 'unassigned')) = 3);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(s1);
  perform pg_temp.chk('sales_admin auto scope = own + unassigned (never a colleague''s)', (select array_agg(lead_name order by lead_name) from list_leads_without_followup()) = array['__TEST_a','__TEST_b','__TEST_d','__TEST_e']);
  perform pg_temp.chk('sales_admin mine scope', (select array_agg(lead_name) from list_leads_without_followup(p_scope => 'mine')) = array['__TEST_e']);
  begin perform list_leads_without_followup(p_scope => 'all'); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('sales_admin cannot ask for scope all', ok = false);
  begin perform list_leads_without_followup(p_scope => 'person', p_assignee => s2); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('sales_admin cannot ask for a colleague''s leads', ok = false);
  perform pg_temp.as_pg();
  for rec in select * from (values ('operation_admin', ops), ('technician', tech), ('customer', cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin perform list_leads_without_followup(); ok := true; exception when others then ok := false; end;
    perform pg_temp.chk('list_leads_without_followup rejected for ' || rec.role, ok = false);
    perform pg_temp.as_pg();
  end loop;
  begin execute 'set local role anon'; perform list_leads_without_followup(); ok := true; exception when others then ok := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('list_leads_without_followup rejected for anon', ok = false);
  perform pg_temp.chk('function not executable by anon / PUBLIC', not has_function_privilege('anon', 'public.list_leads_without_followup(public.lead_status,text,text,text,uuid)', 'execute'));

  -- ===== set_lead_followup ownership =====
  perform pg_temp.as_user(s1);
  begin perform set_lead_followup(c, due_c); ok := true; exception when others then ok := sqlerrm not like '%assigned to someone else%'; end;
  perform pg_temp.chk('sales_admin cannot set a follow-up on a colleague''s lead', ok = false);
  perform set_lead_followup(e, due_c);
  perform set_lead_followup(a, due_c);
  perform pg_temp.chk('sales_admin may set on their own lead and on an unassigned lead', (select count(*) from lead_followups where lead_id in (a, e) and status = 'open') = 2);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(m);
  perform set_lead_followup(c, due_c);
  perform pg_temp.chk('master may set on any lead', (select count(*) from lead_followups where lead_id = c and status = 'open') = 1);
  perform pg_temp.as_pg();
  delete from lead_followups where lead_id in (a, c, e);

  -- ===== set_lead_followups_bulk: spread =====
  -- 7 eligible leads need a 6th and 7th: add two more unassigned open leads (older than a)
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_f','9666666608', now() - interval '9 days') returning id into f_id;
  insert into leads(org_id,name,mobile,created_at) values (v_org,'__TEST_g','9666666609', now() - interval '8 days') returning id into g_id;
  delete from lead_followups where org_id = v_org and lead_id <> sch;
  perform pg_temp.as_user(m);
  select array_agg(lead_id order by created_at) into l from list_leads_without_followup();
  perform pg_temp.chk('setup for the spread: 7 leads without a follow-up', cardinality(l) = 7, cardinality(l)::text);
  r := set_lead_followups_bulk(l, due_c, 'call', 'spread test', 2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('spread: 7 created, none skipped', (r->>'created')::int = 7 and r->'skipped' = '[]'::jsonb, r::text);
  perform pg_temp.chk('spread: per day 2 over four working days (Thu, Fri, Sat, then MONDAY - Sunday skipped)',
    (select array_agg(dy::text order by dy) from (select distinct (due_at at time zone 'Asia/Kolkata')::date dy from lead_followups where org_id = v_org and lead_id <> sch and note = 'spread test') x) = array[thu::text, (thu+1)::text, (thu+2)::text, (thu+4)::text], r::text);
  perform pg_temp.chk('spread: 2,2,2,1 per day', (select array_agg(cn order by dy) from (select (due_at at time zone 'Asia/Kolkata')::date dy, count(*) cn from lead_followups where org_id = v_org and note = 'spread test' group by 1) x) = array[2::bigint,2,2,1]);
  perform pg_temp.chk('spread: day 1 slots are 10:00 and 14:00 IST (two leads spread across 10:00-18:00)',
    (select array_agg(to_char(due_at at time zone 'Asia/Kolkata', 'HH24:MI') order by due_at) from lead_followups where org_id = v_org and note = 'spread test' and (due_at at time zone 'Asia/Kolkata')::date = thu) = array['10:00','14:00']);
  perform pg_temp.chk('spread: the single lead on the last day gets the 10:00 slot', (select to_char(due_at at time zone 'Asia/Kolkata', 'HH24:MI') from lead_followups where org_id = v_org and note = 'spread test' and (due_at at time zone 'Asia/Kolkata')::date = thu + 4) = '10:00');
  perform pg_temp.chk('spread: oldest lead first (the two oldest leads land on day 1)', (select array_agg(lead_id order by lead_id) from lead_followups where org_id = v_org and note = 'spread test' and (due_at at time zone 'Asia/Kolkata')::date = thu) = (select array_agg(x order by x) from unnest(array[f_id, g_id]) x));
  perform pg_temp.chk('spread: every minute is a multiple of 5 and inside 10:00-18:00', not exists (select 1 from lead_followups where org_id = v_org and note = 'spread test' and (extract(minute from due_at at time zone 'Asia/Kolkata')::int % 5 <> 0 or (due_at at time zone 'Asia/Kolkata')::time < '10:00' or (due_at at time zone 'Asia/Kolkata')::time > '18:00')));
  perform pg_temp.chk('spread: rows are manual, typed call, authored by the caller, one open follow-up per lead', (select count(*) from lead_followups where org_id = v_org and note = 'spread test' and source = 'manual' and type = 'call' and created_by = m and status = 'open') = 7);
  perform pg_temp.chk('lead.next_followup_at mirrors the new follow-ups', (select count(*) from leads where id = any(l) and next_followup_at is not null) = 7);

  -- ===== non-spread, skip reasons, validation =====
  delete from lead_followups where org_id = v_org and lead_id <> sch;
  perform pg_temp.as_user(m);
  r := set_lead_followups_bulk(array[a, b, closed, sch, gen_random_uuid(), a], due_c, 'whatsapp', null, null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('non-spread: a, b created (duplicates in the request collapse); closed, scheduled and unknown skipped with reasons',
    (r->>'created')::int = 2
    and (select count(*) from jsonb_array_elements(r->'skipped') x where x->>'lead_id' = closed::text and x->>'reason' = 'closed') = 1
    and (select count(*) from jsonb_array_elements(r->'skipped') x where x->>'lead_id' = sch::text and x->>'reason' = 'has_followup') = 1
    and (select count(*) from jsonb_array_elements(r->'skipped') x where x->>'reason' = 'not_found') = 1, r::text);
  perform pg_temp.chk('non-spread: all at the requested time, type whatsapp', (select count(distinct due_at) from lead_followups where lead_id in (a, b) and status = 'open') = 1 and (select due_at from lead_followups where lead_id = a and status = 'open') = due_c and (select type from lead_followups where lead_id = a and status = 'open') = 'whatsapp');
  delete from lead_followups where lead_id in (a, b);
  perform pg_temp.as_user(m);
  begin perform set_lead_followups_bulk(array[a], now() - interval '2 days', 'call', null, null); ok := true; exception when others then ok := sqlerrm not like '%past%'; end;
  perform pg_temp.chk('non-spread: a past time is rejected', ok = false);
  begin perform set_lead_followups_bulk('{}'::uuid[], due_c); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('empty selection rejected', ok = false);
  begin perform set_lead_followups_bulk(array[a], due_c, 'call', null, 0); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('per_day 0 rejected', ok = false);
  begin perform set_lead_followups_bulk(array[a], due_c, 'call', null, 101); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('per_day 101 rejected', ok = false);
  begin perform set_lead_followups_bulk(array(select gen_random_uuid() from generate_series(1, 201)), due_c); ok := true; exception when others then ok := false; end;
  perform pg_temp.chk('more than 200 leads rejected', ok = false);
  r := set_lead_followups_bulk(array[a], now(), 'call', null, 5);
  perform pg_temp.as_pg();
  perform pg_temp.chk('spread starting "today" begins on the next working day, never in the past', (select (due_at at time zone 'Asia/Kolkata')::date from lead_followups where lead_id = a and status = 'open') > (now() at time zone 'Asia/Kolkata')::date and (select due_at from lead_followups where lead_id = a and status = 'open') > now(), r::text);
  delete from lead_followups where lead_id in (a, b);

  -- ===== sales_admin bulk: own + unassigned only =====
  perform pg_temp.as_user(s1);
  r := set_lead_followups_bulk(array[a, b, c, d], due_c, 'call', null, null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin bulk: unassigned a,b,d scheduled, colleague''s lead c skipped as not_yours', (r->>'created')::int = 3 and (select count(*) from jsonb_array_elements(r->'skipped') x where x->>'lead_id' = c::text and x->>'reason' = 'not_yours') = 1, r::text);
  for rec in select * from (values ('operation_admin', ops), ('technician', tech), ('customer', cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin perform set_lead_followups_bulk(array[c], due_c); ok := true; exception when others then ok := false; end;
    perform pg_temp.chk('bulk rejected for ' || rec.role, ok = false);
    perform pg_temp.as_pg();
  end loop;
  begin execute 'set local role anon'; perform set_lead_followups_bulk(array[c], due_c); ok := true; exception when others then ok := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('bulk rejected for anon', ok = false);
  perform pg_temp.chk('bulk not executable by anon / PUBLIC', not has_function_privilege('anon', 'public.set_lead_followups_bulk(uuid[],timestamptz,public.lead_followup_type,text,integer)', 'execute'));

  -- a deactivated assignee's lead counts as unassigned for scheduling and listing
  update profiles set is_active = false where id = s2;
  perform pg_temp.as_user(s1);
  perform pg_temp.chk('lead of a deactivated assignee is listed as unassigned', exists (select 1 from list_leads_without_followup() where lead_name = '__TEST_c' and assignee_id is null));
  r := set_lead_followups_bulk(array[c], due_c);
  perform pg_temp.as_pg();
  perform pg_temp.chk('...and sales_admin may schedule it', (r->>'created')::int = 1, r::text);
  update profiles set is_active = true where id = s2;

  -- ===== digest sentence (throwaway org only) =====
  delete from lead_followups where org_id = v_org;
  delete from lead_notification_log where key like v_org::text || ':%';
  r := run_lead_followup_notifications(((thu::text || ' 04:30:00+00')::timestamptz), v_org);
  select body into v_body from notifications where org_id = v_org and user_id = m and type = 'lead_followup_digest';
  perform pg_temp.chk('master digest with no follow-ups at all is still sent and names the gap',
    v_body like '0 due today, 0 overdue. Open Daily Follow Up.%' and v_body like '% 8 lead(s) have no follow-up.', coalesce(v_body, 'none'));
  select body into v_body from notifications where org_id = v_org and user_id = s1 and type = 'lead_followup_digest';
  perform pg_temp.chk('sales_admin digest counts only own + unassigned (e own; a,b,d,f,g,sched unassigned = 7; c is s2''s)', v_body like '% 7 lead(s) have no follow-up.', coalesce(v_body, 'none'));
  select body into v_body from notifications where org_id = v_org and user_id = s2 and type = 'lead_followup_digest';
  perform pg_temp.chk('the other sales_admin sees their own c + the six unassigned ones = 7', v_body like '% 7 lead(s) have no follow-up.', coalesce(v_body, 'none'));
  delete from notifications where org_id = v_org and type = 'lead_followup_digest';
  delete from lead_notification_log where key like v_org::text || ':%';
  -- schedule everything (open leads only): no sentence, byte-identical to the old text
  insert into lead_followups (org_id, lead_id, due_at, type, source) select org_id, id, (thu::text || ' 05:30:00+00')::timestamptz, 'call', 'manual' from leads where org_id = v_org and status not in ('won', 'lost');
  r := run_lead_followup_notifications(((thu::text || ' 04:30:00+00')::timestamptz), v_org);
  select body into v_body from notifications where org_id = v_org and user_id = s1 and type = 'lead_followup_digest';
  perform pg_temp.chk('with every open lead scheduled the digest has no "no follow-up" sentence (unchanged text)', v_body is not null and v_body not like '%no follow-up%', coalesce(v_body, 'none'));

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
