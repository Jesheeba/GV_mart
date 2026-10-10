-- Rolled-back DB tests for migration 20261014100000_post_service_followup (batch-17 item 13).
-- One transaction ending in RAISE; read RESULTS in the error. A throwaway __TEST_ organisation is created inside the
-- transaction, so nothing persists and no real lead, ticket or customer row is read or written (the only global reads are
-- the "real data unchanged" fingerprint checks).
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
-- complete a ticket (open -> completed) the way every completion path does: a plain status update
create function pg_temp.complete(p_ticket uuid) returns void language plpgsql as $f$
begin update public.service_tickets set status = 'completed' where id = p_ticket; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_s1 uuid; v_s2 uuid; v_ops uuid; v_cust uuid; v_cust2 uuid;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; t5 uuid; f1 uuid; f2 uuid; l1 uuid;
  txt text; b boolean; n int; r jsonb; rec record; v_body text;
  o_sat uuid; o_issue uuid; o_retry uuid; v_due timestamptz; d date;
  fp1 text; fp2 text; fn1 jsonb;
begin
  select md5(string_agg(id::text||'|'||coalesce(name,'')||'|'||created_at::text||'|'||updated_at::text, ',' order by id)) into fp1 from public.leads;

  insert into organizations (name) values ('__TEST_b17_postservice') returning id into v_org;
  insert into organizations (name) values ('__TEST_b17_postservice_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_s1 := pg_temp.mkuser('sales_admin', v_org);
  v_s2 := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust A', '9400000001') returning id into v_cust;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust B', '9400000002') returning id into v_cust2;

  -- ---------- schema ----------
  perform pg_temp.chk('lead_id is nullable now', (select is_nullable from information_schema.columns where table_schema='public' and table_name='lead_followups' and column_name='lead_id')='YES');
  perform pg_temp.chk('every pre-existing follow-up still has a lead (check constraint holds)', not exists (select 1 from lead_followups where lead_id is null and ticket_id is null));
  perform pg_temp.chk('settings defaults: OFF, 2 days, all sales staff, paid/warranty/installation, dedupe 0',
    (select post_service_followup_enabled = false and post_service_followup_days = 2 and post_service_followup_assignee is null
       and post_service_ticket_types = array['paid','warranty','installation'] and post_service_dedupe_days = 0 from settings where org_id = v_org));
  perform pg_temp.chk('new org seeded 5 post-service outcomes (all built-in)', (select count(*) from post_service_outcomes where org_id=v_org)=5 and (select count(*) from post_service_outcomes where org_id=v_org and is_system)=5);
  perform pg_temp.chk('every pre-existing org was seeded too', not exists (select 1 from organizations o where o.id not in (v_org, v_org2) and (select count(*) from post_service_outcomes x where x.org_id=o.id) < 5));
  select id into o_sat from post_service_outcomes where org_id=v_org and code='satisfied';
  select id into o_issue from post_service_outcomes where org_id=v_org and code='issue_remaining';
  select id into o_retry from post_service_outcomes where org_id=v_org and code='not_reachable';

  -- ---------- ACLs ----------
  perform pg_temp.chk('new RPCs: authenticated + service_role yes, anon + PUBLIC no',
    has_function_privilege('authenticated','public.list_post_service_followups(text,text,uuid)','execute')
    and has_function_privilege('authenticated','public.log_post_service_call(uuid,uuid,text,timestamptz)','execute')
    and has_function_privilege('service_role','public.log_post_service_call(uuid,uuid,text,timestamptz)','execute')
    and not has_function_privilege('anon','public.list_post_service_followups(text,text,uuid)','execute')
    and not has_function_privilege('anon','public.log_post_service_call(uuid,uuid,text,timestamptz)','execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace='public'::regnamespace and p.proname in ('list_post_service_followups','log_post_service_call') and a.grantee = 0));
  perform pg_temp.chk('trigger/seed/guard functions are not executable by anon or authenticated',
    not has_function_privilege('anon','public._trg_ticket_post_service_followup()','execute') and not has_function_privilege('authenticated','public._trg_ticket_post_service_followup()','execute')
    and not has_function_privilege('authenticated','public.seed_post_service_outcomes(uuid)','execute') and not has_function_privilege('anon','public.seed_post_service_outcomes(uuid)','execute')
    and not has_function_privilege('authenticated','public.trg_seed_post_service_outcomes()','execute')
    and not has_function_privilege('authenticated','public._trg_post_service_outcome_guard()','execute'));
  perform pg_temp.chk('no duplicate signatures: one of each', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_post_service_followups')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='log_post_service_call')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='list_followups')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='followup_counts')=1
    and (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='run_lead_followup_notifications')=1);

  -- ---------- trigger: OFF by default ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Not cooling') returning id into t1;
  perform pg_temp.complete(t1);
  perform pg_temp.chk('switch OFF: completing a ticket creates nothing', (select count(*) from lead_followups where ticket_id = t1)=0);

  -- ---------- trigger: ON ----------
  update settings set post_service_followup_enabled = true where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Water leak') returning id into t2;
  perform pg_temp.complete(t2);
  select id, due_at into f1, v_due from lead_followups where ticket_id = t2;
  perform pg_temp.chk('switch ON: completing a paid ticket creates one follow-up', f1 is not null);
  perform pg_temp.chk('row shape: source post_service, type call, status open, customer set, lead null, unassigned',
    (select source='post_service' and type::text='call' and status::text='open' and customer_id=v_cust and lead_id is null and assigned_to is null and ticket_id=t2 from lead_followups where id=f1));
  d := public._lead_ist_date(v_due);
  perform pg_temp.chk('due date = IST today + 2 days, rolled to a working day', d >= public._lead_ist_date(now()) + 2 and public._lead_is_working_day(v_org, d), d::text);
  perform pg_temp.chk('due time = work start + 30 minutes IST', (v_due at time zone 'Asia/Kolkata')::time = (select lead_work_start from settings where org_id=v_org) + interval '30 minutes', ((v_due at time zone 'Asia/Kolkata')::time)::text);

  -- idempotence: reopen + complete again, then complete (no-op update) again
  update service_tickets set status = 'in_progress' where id = t2;
  perform pg_temp.complete(t2);
  update service_tickets set name_of_complaint = 'Water leak (edited)' where id = t2;
  perform pg_temp.chk('idempotent: completed -> reopened -> completed gives still ONE follow-up', (select count(*) from lead_followups where ticket_id = t2)=1);
  begin insert into lead_followups (org_id, ticket_id, customer_id, due_at, source) values (v_org, t2, v_cust, now(), 'post_service'); b := true; exception when unique_violation then b := false; end;
  perform pg_temp.chk('a second follow-up for the same ticket is rejected by the unique index', b = false);
  begin insert into lead_followups (org_id, due_at, source) values (v_org, now(), 'x'); b := true; exception when check_violation then b := false; end;
  perform pg_temp.chk('a follow-up with neither lead nor ticket is rejected', b = false);

  -- skipping rules
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'amc', 'Scheduled AMC visit') returning id into t3;
  perform pg_temp.complete(t3);
  perform pg_temp.chk('ticket type not in the master list (amc) is skipped', (select count(*) from lead_followups where ticket_id = t3)=0);
  update settings set post_service_ticket_types = array['paid','amc'] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'amc', 'Scheduled AMC visit 2') returning id into t4;
  perform pg_temp.complete(t4);
  perform pg_temp.chk('adding amc to the master list makes it eligible', (select count(*) from lead_followups where ticket_id = t4)=1);
  update settings set post_service_dedupe_days = 5 where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'Another visit') returning id into t5;
  perform pg_temp.complete(t5);
  perform pg_temp.chk('dedupe window: same customer within N days is skipped', (select count(*) from lead_followups where ticket_id = t5)=0);
  update settings set post_service_dedupe_days = 0 where org_id = v_org;

  -- delay setting and recipient
  update settings set post_service_followup_days = 0, post_service_followup_assignee = v_s1, post_service_ticket_types = array['paid'] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust2, 'paid', 'Third visit') returning id into t5;
  perform pg_temp.complete(t5);
  perform pg_temp.chk('delay 0 days: due on the IST completion day (or the next working day)', (select public._lead_ist_date(due_at) from lead_followups where ticket_id=t5) in (public._lead_ist_date(now()), public.lead_next_working_day(v_org, public._lead_ist_date(now()))));
  perform pg_temp.chk('recipient setting: assigned_to is the chosen sales person', (select assigned_to from lead_followups where ticket_id=t5) = v_s1);
  update settings set post_service_followup_days = 2, post_service_followup_assignee = null where org_id = v_org;

  -- a failing trigger must not block completion: a ticket whose customer is gone has no customer -> skipped quietly
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'warranty', 'No customer later') returning id into t1;
  update settings set post_service_ticket_types = array['paid','warranty'] where org_id = v_org;
  begin perform pg_temp.complete(t1); b := true; exception when others then b := false; end;
  perform pg_temp.chk('completion itself always succeeds', b);

  -- ---------- list_post_service_followups ----------
  -- f1 (t2): unassigned, f(t4): unassigned, f(t5): assigned to s1
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('master sees all open post-service follow-ups', n = 3 or n = 4, n::text);
  perform pg_temp.as_user(v_s1);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('sales person (own + unassigned) sees own + unassigned', n = (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open'), n::text);
  perform pg_temp.as_user(v_s2);
  select count(*) into n from list_post_service_followups();
  perform pg_temp.chk('another sales person does NOT see the one assigned to s1', n = (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and assigned_to is null), n::text);
  begin perform * from list_post_service_followups('all', 'all'); b := true; exception when others then b := false; end;
  perform pg_temp.chk('sales person cannot ask for the all-scope', b = false);
  select count(*) into n from list_post_service_followups('overdue');
  perform pg_temp.chk('bucket filter works (nothing overdue yet)', n = 0, n::text);
  select * into rec from list_post_service_followups('all') limit 1;
  perform pg_temp.chk('rows carry customer, mobile, complaint, type', rec.customer_name like '__TEST_ Cust%' and rec.mobile like '94000000%' and rec.complaint is not null and rec.ticket_type is not null and rec.attempts = 0);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_ops);
  begin perform * from list_post_service_followups(); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin (not sales staff) cannot list', b = false);
  begin execute 'set local role anon'; perform * from list_post_service_followups(); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot list', b = false);

  -- ---------- untouched lead side ----------
  insert into leads (org_id, name, mobile) values (v_org, '__TEST_ lead', '9400000010') returning id into l1;
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_followups('all');
  perform pg_temp.chk('list_followups returns only the lead follow-up (no ticket rows)', n = 1 and not exists (select 1 from list_followups('all') x where x.lead_id is null), n::text);
  select count(*) into n from list_leads_without_followup();
  perform pg_temp.chk('No follow-up list unaffected by ticket follow-ups', n = 0, n::text);
  fn1 := get_lead_funnel('2000-01-01'::timestamptz, '2100-01-01'::timestamptz);
  perform pg_temp.as_pg();
  perform pg_temp.chk('leads.next_followup_at is set from the lead follow-up only', (select next_followup_at is not null from leads where id=l1));
  perform pg_temp.chk('ticket follow-ups never touched any lead', (select count(*) from leads where org_id=v_org)=1 and (select postpone_count from leads where id=l1)=0);

  -- ---------- followup_counts ----------
  perform pg_temp.as_user(v_master);
  r := followup_counts('all');
  perform pg_temp.as_pg();
  perform pg_temp.chk('followup_counts (master/all) counts lead + post-service follow-ups', (r->>'total')::int = (select count(*) from lead_followups where org_id=v_org and status='open' and public._lead_ist_date(due_at) <= public._lead_ist_date(now())), r::text);
  -- push the ticket follow-ups due today to prove they are counted
  update lead_followups set due_at = now() where org_id=v_org and ticket_id is not null and status='open';
  perform pg_temp.as_user(v_master);
  r := followup_counts('all');
  perform pg_temp.as_pg();
  perform pg_temp.chk('post-service follow-ups due today are in the badge total', (r->>'today')::int >= (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open'), r::text);
  perform pg_temp.chk('by_person lists the sales person who holds the assigned post-service call', exists (select 1 from jsonb_array_elements(r->'by_person') x where (x->>'id')::uuid = v_s1));
  perform pg_temp.as_user(v_s2);
  r := followup_counts('auto');
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales person badge excludes calls assigned to someone else', (r->>'today')::int = (select count(*) from lead_followups f where f.org_id=v_org and f.status='open' and public._lead_ist_date(f.due_at)=public._lead_ist_date(now()) and ((f.ticket_id is not null and f.assigned_to is null) or (f.lead_id is not null))), r::text);

  -- ---------- log_post_service_call ----------
  select id into f1 from lead_followups where ticket_id = t2;
  perform pg_temp.as_user(v_s2);
  r := log_post_service_call(f1, o_sat, E'Customer happy.\nNothing pending.');
  perform pg_temp.as_pg();
  perform pg_temp.chk('satisfied: follow-up done, call recorded', (select status::text from lead_followups where id=f1)='done' and (select count(*) from post_service_calls where followup_id=f1 and outcome_code='satisfied' and called_by=v_s2)=1 and (r->>'status')='done');
  perform pg_temp.chk('note stored verbatim', (select note from post_service_calls where followup_id=f1)=E'Customer happy.\nNothing pending.');
  perform pg_temp.as_user(v_master);
  select count(*) into n from list_post_service_followups() x where x.followup_id = f1;
  perform pg_temp.chk('a done follow-up is gone from the list', n = 0);
  begin perform log_post_service_call(f1, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a done follow-up cannot be logged twice', b = false);

  select id into f2 from lead_followups where ticket_id = t4;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_retry); b := true; exception when others then b := false; end;
  perform pg_temp.chk('retry outcome without a date is refused', b = false);
  r := log_post_service_call(f2, o_retry, 'phone switched off', now() + interval '2 days');
  perform pg_temp.as_pg();
  perform pg_temp.chk('retry outcome: same follow-up stays open with the new date, attempt recorded', (r->>'status')='open' and (select status::text from lead_followups where id=f2)='open' and (select due_at > now() + interval '1 day' from lead_followups where id=f2) and (select count(*) from post_service_calls where followup_id=f2)=1);
  perform pg_temp.chk('retry keeps one follow-up per ticket', (select count(*) from lead_followups where ticket_id=t4)=1);
  perform pg_temp.as_user(v_master);
  select attempts, last_outcome_code into rec from list_post_service_followups() x where x.followup_id = f2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('list shows attempts and last outcome', rec.attempts = 1 and rec.last_outcome_code = 'not_reachable');

  -- alert outcome notifies master + operation_admin, not sales_admin
  perform pg_temp.as_user(v_s1);
  r := log_post_service_call(f2, o_issue, 'Still leaking');
  perform pg_temp.as_pg();
  perform pg_temp.chk('issue outcome: follow-up done and alerted', (r->>'status')='done' and (r->>'alerted')::boolean);
  perform pg_temp.chk('alert went to master and operation_admin only', (select count(*) from notifications where org_id=v_org and type='post_service_issue' and ref_id=t4 and user_id in (v_master, v_ops))=2
    and not exists (select 1 from notifications where org_id=v_org and type='post_service_issue' and user_id in (v_s1, v_s2)));
  perform pg_temp.chk('alert text carries the note', (select body like '%Still leaking%' from notifications where org_id=v_org and type='post_service_issue' and user_id=v_master limit 1));

  -- guards
  select id into f2 from lead_followups where ticket_id = t5;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_sat, repeat('x', 2001)); b := true; exception when others then b := false; end;
  perform pg_temp.chk('2001-character note refused', b = false);
  begin perform log_post_service_call((select id from lead_followups where lead_id = l1 and status='open'), o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.chk('a LEAD follow-up cannot be logged through the post-service RPC', b = false);
  begin perform log_post_service_call(f2, gen_random_uuid()); b := true; exception when others then b := false; end;
  perform pg_temp.chk('unknown outcome refused', b = false);
  perform pg_temp.as_pg();
  update post_service_outcomes set is_active = false where id = o_sat;
  perform pg_temp.as_user(v_s2);
  begin perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('inactive outcome refused', b = false);
  update post_service_outcomes set is_active = true where id = o_sat;
  perform pg_temp.as_user(pg_temp.mkuser('customer', v_org));
  begin perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('customer-role user cannot log a call', b = false);
  begin execute 'set local role anon'; perform log_post_service_call(f2, o_sat); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot log a call', b = false);

  -- master list: RLS + guards
  perform pg_temp.as_user(v_s1);
  begin insert into post_service_outcomes (org_id, code, label_en, label_ta) values (v_org, 'x', 'X', 'X'); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales person cannot edit the outcome list', b = false);
  perform pg_temp.as_user(v_master);
  insert into post_service_outcomes (org_id, code, label_en, label_ta, retry) values (v_org, 'wants_visit', 'Wants another visit', 'மற்றொரு வருகை', false);
  update post_service_outcomes set label_en = 'Wants another visit!' where org_id=v_org and code='wants_visit';
  begin delete from post_service_outcomes where org_id=v_org and code='satisfied'; get diagnostics n = row_count; b := n > 0; exception when others then b := false; end;
  perform pg_temp.chk('master can add/edit a custom outcome; built-in outcome cannot be deleted', b = false and exists (select 1 from post_service_outcomes where org_id=v_org and code='wants_visit' and label_en='Wants another visit!'));
  begin delete from post_service_outcomes where org_id=v_org and code='wants_visit'; b := true; exception when others then b := false; end;
  perform pg_temp.chk('an unused custom outcome can be deleted', b and not exists (select 1 from post_service_outcomes where org_id=v_org and code='wants_visit'));
  begin update post_service_outcomes set code = 'renamed' where org_id=v_org and code='call_later'; b := true; exception when others then b := false; end;
  perform pg_temp.chk('outcome code cannot change', b = false);
  begin delete from post_service_outcomes where id = o_issue; b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an outcome used by a call cannot be deleted (also built-in)', b = false);
  perform pg_temp.as_user(v_s1);
  select count(*) into n from post_service_calls;
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff can read the call history', n >= 3, n::text);
  perform pg_temp.as_user(v_s1);
  begin insert into post_service_calls (org_id, followup_id, ticket_id, outcome_id, outcome_code) values (v_org, f2, t5, o_sat, 'satisfied'); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('no client write policy on post_service_calls', b = false);

  -- ---------- digest ----------
  -- fresh org-level state: one lead follow-up due that day + one post-service call due that day
  update lead_followups set due_at = timestamptz '2026-10-13 15:00:00+05:30' where lead_id = l1 and status='open';
  update lead_followups set due_at = timestamptz '2026-10-13 14:00:00+05:30', status='open' where ticket_id = t5;
  update settings set lead_work_days = array[1,2,3,4,5,6], lead_work_start='09:30', lead_work_end='19:00' where org_id = v_org;
  r := run_lead_followup_notifications(timestamptz '2026-10-13 11:00:00+05:30', v_org);
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_master and n.type='lead_followup_digest';
  perform pg_temp.chk('master digest counts every open post-service call due',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and public._lead_ist_date(due_at) <= date '2026-10-13')), v_body);
  perform pg_temp.chk('digest still has the lead sentence and Daily Follow Up wording', v_body like '1 due today, 0 overdue. Open Daily Follow Up.%', v_body);
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_s2 and n.type='lead_followup_digest';
  perform pg_temp.chk('a sales person is told only about unassigned calls, not the one assigned to a colleague',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and assigned_to is null and public._lead_ist_date(due_at) <= date '2026-10-13')), coalesce(v_body,'<none>'));
  select n.body into v_body from notifications n where n.org_id=v_org and n.user_id=v_s1 and n.type='lead_followup_digest';
  perform pg_temp.chk('the sales person it is assigned to is told about it plus the unassigned ones',
    v_body like format('%% %s post-service call(s) due.%%', (select count(*) from lead_followups where org_id=v_org and ticket_id is not null and status='open' and (assigned_to is null or assigned_to = v_s1) and public._lead_ist_date(due_at) <= date '2026-10-13')), coalesce(v_body,'<none>'));

  -- digest with ONLY a post-service call due still goes out
  insert into organizations (name) values ('__TEST_b17_postservice_digest_only') returning id into v_org2;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  update settings set post_service_followup_enabled = true, lead_work_days = array[1,2,3,4,5,6] where org_id = v_org2;
  declare m2 uuid; c2 uuid; tk uuid;
  begin
    m2 := pg_temp.mkuser('master', v_org2);
    insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ C', '9400000099') returning id into c2;
    insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org2, c2, 'paid', 'x') returning id into tk;
    perform pg_temp.complete(tk);
    update lead_followups set due_at = timestamptz '2026-10-13 14:00:00+05:30' where ticket_id = tk;
    r := run_lead_followup_notifications(timestamptz '2026-10-13 11:00:00+05:30', v_org2);
    select n.body into v_body from notifications n where n.org_id=v_org2 and n.user_id=m2 and n.type='lead_followup_digest';
    perform pg_temp.chk('digest is sent when the only thing due is a post-service call', v_body like '%1 post-service call(s) due.%', coalesce(v_body,'<none>'));
  end;

  -- ---------- real data untouched ----------
  select md5(string_agg(id::text||'|'||coalesce(name,'')||'|'||created_at::text||'|'||updated_at::text, ',' order by id)) into fp2 from public.leads where name not like '\_\_TEST%';
  perform pg_temp.chk('real leads untouched by everything above (identity + updated_at fingerprint)', fp1 is not distinct from fp2);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
