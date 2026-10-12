-- Rolled-back DB tests for migration 20261017100000_automation_phase2_foundation (automation Phase 2).
-- Run AFTER the migration (the runner concatenates the migration in front of this file inside ONE transaction, so even the
-- DDL is rolled back). The block ends in RAISE; read RESULTS in the error. A throwaway __TEST_ organisation is created
-- inside the transaction; no real customer, number or message is touched, and nothing is sent (there is no sender here).
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
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
-- run a statement; record a FAIL with the error text instead of aborting the whole test
create function pg_temp.try(p_name text, p_sql text) returns boolean language plpgsql as $f$
begin execute p_sql; return true;
exception when others then
  insert into pg_temp.res(line) values ('FAIL  ' || p_name || '  [' || sqlerrm || ']'); return false;
end $f$;
-- true when the statement raises
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master2 uuid; v_ops uuid; v_sales uuid; v_tp uuid; v_custrole uuid;
  v_cust uuid; v_cust_t uuid; v_ticket uuid; v_ticket_t uuid; v_tech uuid; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_inv uuid; v_lead uuid; v_lead_t uuid; v_rule_c uuid; v_rule_n uuid; v_rule_k uuid; v_rule_paused uuid; v_rk uuid;
  v_ev uuid; v_mob text := '9400000077'; v_real text := '9400000066';
  n int; n2 int; s text; b boolean; rec record; fp_cust text; fp_out int; v_ver int; v_cur int;
  v_ob1 int; v_ob2 int; v_e1 int; v_e2 int; v_l uuid; v_tk2 uuid;
begin
  select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) into fp_cust
    from public.customers where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  -- ---------- schema / privileges ----------
  perform pg_temp.chk('seven automation tables exist and have RLS enabled',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors')) = 7);
  perform pg_temp.chk('automation_emit: not executable by PUBLIC / anon / authenticated, executable by service_role',
    not has_function_privilege('anon', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                    where p.oid = 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)'::regprocedure and a.grantee = 0));
  perform pg_temp.chk('automation_emit is SECURITY DEFINER with a fixed search_path',
    (select p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
       from pg_proc p where p.oid = 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)'::regprocedure));
  perform pg_temp.chk('every emit trigger function is SECURITY DEFINER, fixed search_path, not executable by anon/authenticated',
    (select count(*) = 7 and bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
        and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute'))
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like '\_trg\_automation\_emit\_%'));
  perform pg_temp.chk('no client write privilege on any automation table; anon cannot read them',
    not exists (select 1 from unnest(array['automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors']) t,
                     unnest(array['anon','authenticated']) r, unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) pr
                where has_table_privilege(r, 'public.' || t, pr))
    and not exists (select 1 from unnest(array['automation_events','automation_flow_defs','automation_rules','automation_event_log','automation_audit','automation_queue','automation_errors']) t
                where has_table_privilege('anon', 'public.' || t, 'SELECT')));
  perform pg_temp.chk('automation_rule_save: authenticated + service_role only',
    has_function_privilege('authenticated', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)', 'execute')
    and not has_function_privilege('anon', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)', 'execute'));
  perform pg_temp.chk('catalogue holds the events the owner named (AMC join/end, spare + product enquiry) and every group',
    (select count(*) from public.automation_events where event_key in ('amc.joined','amc.expired','amc.expiring','spare_enquiry.submitted','product_enquiry.submitted','review.google_requested')) = 6
    and (select count(distinct group_key) from public.automation_events) >= 8
    and (select count(*) from public.automation_events) >= 60);
  perform pg_temp.chk('technician.on_the_way has NO emitter (no departure signal); technician.arrived has one',
    not (select has_emitter from public.automation_events where event_key = 'technician.on_the_way')
    and (select has_emitter from public.automation_events where event_key = 'technician.arrived'));
  perform pg_temp.chk('automation is enabled by default and the F-08 allow-list is OFF by default',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_enabled') = 'true'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'wa_test_mode_enabled') = 'false');
  perform pg_temp.chk('conditions: equality, any-of, min/max, missing key',
    public._automation_conditions_match('{"t":"paid"}', '{"t":"paid"}')
    and not public._automation_conditions_match('{"t":"paid"}', '{"t":"amc"}')
    and public._automation_conditions_match('{"t":["paid","amc"]}', '{"t":"amc"}')
    and public._automation_conditions_match('{"min_total":100,"max_total":500}', '{"total":250}')
    and not public._automation_conditions_match('{"min_total":100}', '{"total":50}')
    and not public._automation_conditions_match('{"x":"1"}', '{}')
    and public._automation_conditions_match('{}', '{"a":1}'));

  -- ---------- throwaway org ----------
  insert into organizations (name) values ('__TEST_automation_p2') returning id into v_org;
  insert into organizations (name) values ('__TEST_automation_p2_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_custrole := pg_temp.mkuser('customer', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Real-ish', v_real) returning id into v_cust;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ Flagged', v_mob, true) returning id into v_cust_t;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 1, 3000, 1) returning id into v_plan;

  -- ---------- rules: master saves; others cannot ----------
  perform pg_temp.as_user(v_master);
  v_rule_c := public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"paid"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live');
  v_rule_n := public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"warranty"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live');
  v_rule_k := public.automation_rule_save(null, 'ticket.completed', 'operations', 'in_app', '{}', null, null, 0, 0, null, 'test_only');
  v_rule_paused := public.automation_rule_save(null, 'ticket.completed', 'sales', 'in_app', '{}', null, null, 0, 0, null, 'paused');
  perform pg_temp.chk('master saved four rules (version 1, current)',
    (select count(*) from public.automation_rules where org_id = v_org and version = 1 and is_current) = 4);
  perform pg_temp.chk('rule save writes a config_changed audit row each',
    (select count(*) from public.automation_audit where org_id = v_org and decision = 'config_changed') = 4);
  s := pg_temp.raises(format($q$select public.automation_rule_save(null, 'amc.expiring', 'technician', 'whatsapp')$q$));
  perform pg_temp.chk('rule for a recipient the event does not support is refused', s like '%does not support recipient%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'no.such_event', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('rule for an unknown event is refused', s like '%unknown event%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('sales_admin cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('operation_admin cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_tp);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('technician cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_custrole);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('customer role cannot save a rule', s like '%only the master%', coalesce(s,'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'ticket.completed', 'customer', 'whatsapp')$q$);
  perform pg_temp.chk('anon cannot call automation_rule_save', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$select public.automation_emit(%L, 'ticket.created', 'ticket', gen_random_uuid())$q$, v_org));
  perform pg_temp.chk('anon cannot call automation_emit', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$select public.automation_emit(%L, 'ticket.created', 'ticket', gen_random_uuid())$q$, v_org));
  perform pg_temp.chk('even the master (authenticated) cannot call automation_emit directly', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_pg();

  -- ---------- every existing event is audited (no rule needed): one event_log row each ----------
  -- tickets (rules exist for ticket.completed only; the other ticket events have none -> outcome no_rule)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ real ticket') returning id into v_ticket;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust_t, 'paid', '__TEST_ flagged ticket') returning id into v_ticket_t;
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.created';
  perform pg_temp.chk('ticket.created: one event_log row per ticket, even with no matching rule', n = 2, n::text);
  perform pg_temp.chk('ticket.created rows say no_rule and carry the right test tag',
    (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and outcome = 'no_rule') = 2
    and (select is_test from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and subject_id = v_ticket_t)
    and not (select is_test from public.automation_event_log where org_id = v_org and event_key = 'ticket.created' and subject_id = v_ticket));

  update service_tickets set status = 'assigned' where id in (v_ticket, v_ticket_t);
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.assigned';
  perform pg_temp.chk('ticket.assigned: one row per ticket', n = 2, n::text);

  -- visits
  perform pg_temp.try('visit insert (real)', format($q$insert into service_visits (org_id, ticket_id, technician_id) values (%L, %L, %L)$q$, v_org, v_ticket, v_tech));
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'technician.arrived' and subject_type = 'visit';
  perform pg_temp.chk('technician.arrived emitted on visit insert', n = 1, n::text);
  perform pg_temp.chk('technician.on_the_way never emitted',
    not exists (select 1 from public.automation_event_log where org_id = v_org and event_key = 'technician.on_the_way'));

  -- completion: real ticket (paid) and flagged ticket (paid) -> 4 rules each
  update service_tickets set status = 'completed' where id = v_ticket;
  update service_tickets set status = 'completed' where id = v_ticket_t;
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'ticket.completed';
  perform pg_temp.chk('ticket.completed: one row per ticket', n = 2, n::text);

  -- rule that matches / does not match
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c and event_key = 'ticket.completed';
  perform pg_temp.chk('MATCHING rule (live, ticket_type=paid) on the real customer -> dry_run', s = 'dry_run', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_n and event_key = 'ticket.completed';
  perform pg_temp.chk('NON-matching rule (ticket_type=warranty) -> skipped_condition', s = 'skipped_condition', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_k and event_key = 'ticket.completed';
  perform pg_temp.chk('test_only rule on a REAL customer -> skipped_test_only (never queued)', s = 'skipped_test_only', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket_t and rule_id = v_rule_k and event_key = 'ticket.completed';
  perform pg_temp.chk('test_only rule on the FLAGGED customer -> dry_run', s = 'dry_run', coalesce(s, 'no row'));
  select decision into s from public.automation_audit where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_paused and event_key = 'ticket.completed';
  perform pg_temp.chk('paused rule -> skipped_paused', s = 'skipped_paused', coalesce(s, 'no row'));
  perform pg_temp.chk('every considered rule has an audit row (4 rules x 2 events = 8)',
    (select count(*) from public.automation_audit where org_id = v_org and event_key = 'ticket.completed' and decision <> 'config_changed') = 8);
  perform pg_temp.chk('event_log counts: considered 4, queued as dry_run',
    (select rules_considered = 4 and outcome = 'processed' from public.automation_event_log where org_id = v_org and event_key = 'ticket.completed' and subject_id = v_ticket));
  perform pg_temp.chk('queue rows only ever dry_run, never a deliverable state',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run','blocked_not_allowlisted')));
  s := pg_temp.raises(format($q$insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id, recipient_role, channel, fire_at, state)
        values (%L, 'x', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'a.b', 'ticket', gen_random_uuid(), 'customer', 'whatsapp', now(), 'pending')$q$, v_org));
  perform pg_temp.chk('queue CHECK refuses a "pending"/deliverable state', s like '%check constraint%', coalesce(s,'accepted'));

  -- ---------- test-flag isolation ----------
  perform pg_temp.chk('flagged customer events and queue rows are tagged is_test',
    (select bool_and(is_test) from public.automation_queue where org_id = v_org and subject_id = v_ticket_t)
    and (select bool_and(is_test) from public.automation_audit where org_id = v_org and subject_id = v_ticket_t and decision <> 'config_changed'));
  perform pg_temp.chk('nothing for a test subject is addressed anywhere but the test number',
    not exists (select 1 from public.automation_queue q where q.org_id = v_org and q.is_test
                  and q.recipient_masked is not null and q.recipient_masked <> '******' || right(v_mob, 4)));
  perform pg_temp.chk('the real customer queue row is addressed to the real (masked) number only',
    (select recipient_masked from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c) = '******' || right(v_real, 4));
  perform pg_temp.chk('no full phone number is stored in queue or audit',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked ~ '[0-9]{7,}')
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked ~ '[0-9]{7,}'));

  -- a flagged lead (by mobile) pointed at a real number is blocked even with test mode OFF
  insert into leads (org_id, name, mobile, source, status, kind) values (v_org, '__TEST_ L by mobile', '+91 ' || v_mob, 'field', 'new', 'service') returning id into v_lead_t;
  perform pg_temp.chk('lead sharing the test number is flagged is_test (existing sync) and logged lead.created is_test',
    (select is_test from leads where id = v_lead_t)
    and (select is_test from public.automation_event_log where org_id = v_org and subject_id = v_lead_t and event_key = 'lead.created'));
  perform pg_temp.as_user(v_master);
  v_rk := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', 'gvm_lead_welcome_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, null, 'probe-real-dest', jsonb_build_object('mobile', v_real));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_rk;
  perform pg_temp.chk('test subject aimed at a NON-test number is blocked (hard stop, test mode OFF)',
    rec.decision = 'blocked_not_allowlisted' and rec.reason = 'test_subject_destination_not_a_test_number', coalesce(rec.decision,'-') || '/' || coalesce(rec.reason,'-'));
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, null, 'probe-test-dest', jsonb_build_object('mobile', v_mob));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rk;
  perform pg_temp.chk('test subject aimed at the test number is allowed (dry_run)', s = 'dry_run', coalesce(s,'-'));

  -- ---------- allow-list (F-08 setting, reused) ----------
  select count(*) into n from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED';
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = array[v_mob] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe', jsonb_build_object('ticket_type', 'paid'));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: non-test number not on the list -> blocked_not_allowlisted',
    rec.decision = 'blocked_not_allowlisted' and rec.reason = 'test_mode_not_allow_listed', coalesce(rec.decision,'-'));
  perform pg_temp.chk('blocked queue row is state blocked_not_allowlisted and counted as not queued',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rule_c) = 'blocked_not_allowlisted'
    and (select rules_queued from public.automation_event_log where id = v_ev) = 0);
  select count(*) into n2 from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED';
  perform pg_temp.chk('block is logged in audit_log with last four digits only',
    n2 = n + 1
    and not exists (select 1 from public.audit_log where org_id = v_org and action = 'WA_SEND_BLOCKED' and after::text ~ '[0-9]{7,}'));
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket_t, v_cust_t, 'allowlist-probe', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: the test number itself passes (dry_run)', s = 'dry_run', coalesce(s,'-'));
  update settings set wa_test_allowed_numbers = array[v_mob, v_real] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe-2', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list ON: a listed number passes', s = 'dry_run', coalesce(s,'-'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}' where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'allowlist-probe-3', jsonb_build_object('ticket_type', 'paid'));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('allow-list OFF (default): not blocked, still only a dry_run', s = 'dry_run', coalesce(s,'-'));

  -- ---------- duplicate emit idempotency ----------
  select count(*) into n from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  select count(*) into n2 from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c;
  perform pg_temp.chk('re-emitting the same event/subject/occurrence adds NO queue row', n2 = n, n::text || ' -> ' || n2::text);
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rule_c;
  perform pg_temp.chk('the repeat is audited as skipped_duplicate and the event log still has the entry',
    s = 'skipped_duplicate' and (select outcome from public.automation_event_log where id = v_ev) in ('duplicate', 'processed'),
    coalesce(s,'-'));
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  perform pg_temp.chk('a flip-flopped status (trigger fires again) cannot re-notify either',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_id = v_rule_c and idempotency_key like '%|completed|live|-') = 1);

  -- ---------- rule versions: an edit never re-fires old occurrences ----------
  perform pg_temp.as_user(v_master);
  v_rk := (select rule_key from public.automation_rules where id = v_rule_c);
  v_rule_c := public.automation_rule_save(v_rk, 'ticket.completed', 'customer', 'whatsapp', '{"ticket_type":"paid"}', 'gvm_service_completed_en', 'en', 0, 0, null, 'live', null, 'v2');
  perform pg_temp.as_pg();
  select count(*) filter (where is_current), max(version) into v_cur, v_ver from public.automation_rules where org_id = v_org and rule_key = v_rk;
  perform pg_temp.chk('editing a rule inserts version 2 and leaves exactly one current', v_cur = 1 and v_ver = 2);
  select count(*) into n from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_key = v_rk;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', v_ticket, v_cust, 'completed', jsonb_build_object('ticket_type', 'paid'));
  select count(*) into n2 from public.automation_queue where org_id = v_org and subject_id = v_ticket and rule_key = v_rk;
  perform pg_temp.chk('version 2 does not re-fire an occurrence version 1 already handled', n = n2);

  -- ---------- cooldown / max fires ----------
  perform pg_temp.as_user(v_master);
  v_rk := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', null, null, 0, 24, null, 'live');
  v_rule_n := public.automation_rule_save(null, 'invoice.paid', 'customer', 'whatsapp', '{}', null, null, 0, 0, 1, 'live');
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_cust, 'a', '{}');
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_cust, 'a', '{}');
  perform pg_temp.chk('cooldown: second send to the same customer inside the window -> skipped_cooldown',
    (select count(*) from public.automation_audit where org_id = v_org and event_id = v_ev and decision = 'skipped_cooldown') = 1);
  v_inv := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'invoice.paid', 'invoice', v_inv, v_cust, 'paid-1', '{}');
  v_ev := public.automation_emit(v_org, 'invoice.paid', 'invoice', v_inv, v_cust, 'paid-2', '{}');
  perform pg_temp.chk('max_fires=1: second occurrence for the same subject -> skipped_max_fires',
    (select count(*) from public.automation_audit where org_id = v_org and event_id = v_ev and decision = 'skipped_max_fires') = 1);

  -- ---------- global kill switch + unknown event ----------
  update settings set automation_enabled = false where org_id = v_org;
  select count(*) into n from public.automation_audit where org_id = v_org;
  select count(*) into n2 from public.automation_queue where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.completed', 'ticket', gen_random_uuid(), v_cust, 'kill-1', jsonb_build_object('ticket_type', 'paid'));
  perform pg_temp.chk('global OFF: event is still logged (global_off) but nothing is audited or queued',
    (select outcome from public.automation_event_log where id = v_ev) = 'global_off'
    and (select count(*) from public.automation_audit where org_id = v_org) = n
    and (select count(*) from public.automation_queue where org_id = v_org) = n2);
  update settings set automation_enabled = true where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'not.an_event', 'ticket', gen_random_uuid(), null, '', '{}');
  perform pg_temp.chk('unknown event key is logged as unknown_event, not rejected',
    (select outcome from public.automation_event_log where id = v_ev) = 'unknown_event');

  -- ---------- more existing emitters (each logged once, no rule required) ----------
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cust, 'product', 100, 100, 'due') returning id into v_inv;
  update invoices set payment_status = 'partial', amount_paid = 40 where id = v_inv;
  update invoices set payment_status = 'paid', amount_paid = 100 where id = v_inv;
  perform pg_temp.chk('invoice.issued / partial / paid each logged once',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.issued') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.partial') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'invoice.paid') = 1);

  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L product', '9400000055', 'customer_app', 'new', 'product') returning id into v_lead;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L spare', '9400000054', 'customer_app', 'new', 'spare');
  perform pg_temp.chk('product lead -> lead.created + product_enquiry.submitted; spare lead -> spare_enquiry.submitted',
    (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'product_enquiry.submitted' and subject_id = v_lead) = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'spare_enquiry.submitted') = 1
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'lead.created' and subject_id = v_lead) = 1);
  update leads set status = 'contacted' where id = v_lead;
  update leads set status = 'quoted' where id = v_lead;
  update leads set status = 'lost', lost_reason = '__TEST_' where id = v_lead;
  perform pg_temp.chk('lead stage changes logged per stage', (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key in ('lead.stage.contacted','lead.stage.quoted','lead.stage.lost')) = 3);
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L assign', '9400000053', 'customer_app', 'new', 'service') returning id into v_inv;
  perform pg_temp.as_user(v_master);
  perform public.assign_lead(v_inv, v_sales, 'test');
  perform pg_temp.as_pg();
  perform pg_temp.chk('lead sales-person change logs lead.assigned',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_inv and event_key = 'lead.assigned') >= 1);

  if pg_temp.try('amc contract insert', format($q$insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values (%L, %L, %L, %L, current_date, current_date + 365, 'active')$q$, v_org, v_cust, v_prod, v_plan)) then
    perform pg_temp.chk('amc.joined logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.joined') = 1);
    update amc_contracts set status = 'expired' where org_id = v_org and customer_id = v_cust;
    perform pg_temp.chk('amc.expired logged on status change', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.expired') = 1);
  end if;
  if pg_temp.try('warranty insert', format($q$insert into warranties (org_id, customer_id, product_id, start_date, expiry_date) values (%L, %L, %L, current_date, current_date + 365)$q$, v_org, v_cust, v_prod)) then
    perform pg_temp.chk('warranty.started logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'warranty.started') = 1);
  end if;
  if pg_temp.try('quotation insert', format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 500)$q$, v_org, v_cust)) then
    update quotations set status = 'converted' where org_id = v_org and customer_id = v_cust;
    perform pg_temp.chk('quotation.created and quotation.converted logged',
      (select count(*) from public.automation_event_log where org_id = v_org and event_key in ('quotation.created','quotation.converted')) = 2);
  end if;
  update service_tickets set status = 'cancelled' where id = (select id from service_tickets where org_id = v_org and status = 'open' limit 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ to cancel') returning id into v_ticket;
  update service_tickets set status = 'cancelled' where id = v_ticket;
  perform pg_temp.chk('ticket.cancelled logged', (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'ticket.cancelled' and subject_id = v_ticket) = 1);

  perform pg_temp.chk('payload VALUES are never stored in the event log (keys only)',
    not exists (select 1 from public.automation_event_log where org_id = v_org and payload_keys::text ~ '[0-9]{7,}'));

  -- ---------- triggers fire only on the intended changes ----------
  perform pg_temp.chk('trigger definitions: column-limited UPDATE OF, and insert-only where intended',
    (select count(*) = 7 from pg_trigger where tgname like 'zz\_automation\_emit\_%' and not tgisinternal)
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_ticket')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_invoice')) ~ 'AFTER INSERT OR UPDATE OF payment_status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_lead')) ~ 'AFTER INSERT OR UPDATE OF status, assigned_to ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_amc')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_quotation')) ~ 'AFTER INSERT OR UPDATE OF status ON'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_visit')) !~ 'UPDATE'
    and pg_get_triggerdef((select oid from pg_trigger where tgname = 'zz_automation_emit_warranty')) !~ 'UPDATE');
  insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (v_org, v_cust, '__TEST_ L specificity', '9400000052', 'customer_app', 'new', 'service') returning id into v_l;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_ specificity') returning id into v_tk2;
  select count(*) into v_e1 from public.automation_event_log where org_id = v_org;
  update leads set notes = '__TEST_ note' where id = v_l;
  update leads set name = name, mobile = mobile, status = status where id = v_l;
  update service_tickets set name_of_complaint = '__TEST_ renamed' where id = v_tk2;
  update service_tickets set status = status, priority = priority where id = v_tk2;
  update invoices set total = total, discount = discount, payment_status = payment_status where id = v_inv;
  update customers set name = name where id = v_cust;
  update amc_contracts set next_service_date = next_service_date, status = status where org_id = v_org;
  select count(*) into v_e2 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('updates that change no emitting column, and repeated no-op UPDATEs, emit nothing', v_e1 = v_e2, v_e1::text || ' -> ' || v_e2::text);
  update leads set status = 'contacted' where id = v_l;
  select count(*) into v_e1 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('a real stage change emits exactly one event',
    v_e1 = v_e2 + 1 and (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_l and event_key = 'lead.stage.contacted') = 1);
  update leads set status = 'contacted' where id = v_l;
  update leads set status = 'contacted', notes = '__TEST_ again' where id = v_l;
  select count(*) into v_e2 from public.automation_event_log where org_id = v_org;
  perform pg_temp.chk('repeating the same stage UPDATE emits nothing', v_e1 = v_e2, v_e1::text || ' -> ' || v_e2::text);
  update service_tickets set status = 'assigned' where id = v_tk2;
  update service_tickets set status = 'assigned' where id = v_tk2;
  perform pg_temp.chk('a repeated ticket status UPDATE emits once',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_tk2 and event_key = 'ticket.assigned') = 1);
  update service_tickets set status = 'in_progress' where id = v_tk2;
  perform pg_temp.chk('a status the catalogue has no event for (in_progress) emits nothing',
    (select count(*) from public.automation_event_log where org_id = v_org and subject_id = v_tk2) = 2);

  -- ---------- nothing delivered: the engine never touches the outbox ----------
  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org;
  perform public.automation_emit(v_org, 'ticket.completed', 'ticket', gen_random_uuid(), v_cust, 'outbox-probe', jsonb_build_object('ticket_type', 'paid'));
  perform public.automation_emit(v_org, 'lead.created', 'lead', v_lead_t, null, 'outbox-probe', jsonb_build_object('mobile', v_mob));
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('automation_emit wrote nothing to whatsapp_outbox (no send path)', v_ob1 = v_ob2, v_ob1::text || ' -> ' || v_ob2::text);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched by the migration (still its default / not set true here)',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));

  -- ---------- append-only ----------
  s := pg_temp.raises(format($q$update public.automation_event_log set outcome = 'no_rule' where org_id = %L$q$, v_org));
  perform pg_temp.chk('event_log: UPDATE refused (owner)', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$delete from public.automation_audit where org_id = %L$q$, v_org));
  perform pg_temp.chk('audit: DELETE refused (owner)', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$truncate public.automation_event_log$q$);
  perform pg_temp.chk('event_log: TRUNCATE refused', s like '%append-only%', coalesce(s,'accepted'));
  s := pg_temp.raises($q$truncate public.automation_audit$q$);
  perform pg_temp.chk('audit: TRUNCATE refused', s like '%append-only%', coalesce(s,'accepted'));
  execute 'set local role service_role';
  s := pg_temp.raises(format($q$update public.automation_audit set decision = 'dry_run' where org_id = %L$q$, v_org));
  perform pg_temp.chk('audit: UPDATE refused even for service_role', s is not null, coalesce(s,'accepted'));
  perform pg_temp.as_pg();
  s := pg_temp.raises(format($q$update public.automation_rules set conditions = '{}' where org_id = %L$q$, v_org));
  perform pg_temp.chk('rules: in-place edit refused (immutable versions)', s like '%immutable%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$delete from public.automation_rules where org_id = %L$q$, v_org));
  perform pg_temp.chk('rules: DELETE refused', s like '%immutable%', coalesce(s,'accepted'));

  -- ---------- deleting an author's profile must not be blocked by rule immutability ----------
  v_ops := pg_temp.mkuser('master', v_org);
  perform pg_temp.as_user(v_ops);
  v_rk := public.automation_rule_save(null, 'invoice.partial', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'paused');
  perform pg_temp.as_pg();
  if pg_temp.try('delete author profile', format($q$delete from public.profiles where id = %L$q$, v_ops)) then
    perform pg_temp.chk('rule survives its author being deleted, created_by set to NULL',
      (select created_by is null from public.automation_rules where id = v_rk));
  end if;
  v_ops := pg_temp.mkuser('operation_admin', v_org);

  -- ---------- RLS: who can read what ----------
  perform pg_temp.as_user(v_master);
  select count(*) into n from public.automation_event_log;
  select count(*) into n2 from public.automation_audit where org_id <> v_org;
  perform pg_temp.chk('master reads own org event_log and no other org', n > 0 and n2 = 0 and not exists (select 1 from public.automation_event_log where org_id <> v_org), n::text);
  perform pg_temp.as_user(v_ops);
  perform pg_temp.chk('operation_admin reads event_log, audit, rules and queue',
    (select count(*) from public.automation_event_log) > 0 and (select count(*) from public.automation_audit) > 0
    and (select count(*) from public.automation_rules) > 0 and (select count(*) from public.automation_queue) > 0);
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin sees no automation rows (but may read the catalogue)',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0
    and (select count(*) from public.automation_events) > 0);
  perform pg_temp.as_user(v_tp);
  perform pg_temp.chk('technician sees no automation rows',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0);
  perform pg_temp.as_user(v_custrole);
  perform pg_temp.chk('customer role sees no automation rows and not even the catalogue',
    (select count(*) from public.automation_event_log) = 0 and (select count(*) from public.automation_audit) = 0
    and (select count(*) from public.automation_rules) = 0 and (select count(*) from public.automation_queue) = 0
    and (select count(*) from public.automation_events) = 0);
  perform pg_temp.as_user(v_master2);
  perform pg_temp.chk('another organisation master sees none of this org',
    (select count(*) from public.automation_event_log where org_id = v_org) = 0
    and (select count(*) from public.automation_rules where org_id = v_org) = 0
    and (select count(*) from public.automation_audit where org_id = v_org) = 0);
  perform pg_temp.as_anon();
  s := pg_temp.raises($q$select count(*) from public.automation_event_log$q$);
  perform pg_temp.chk('anon: read refused', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$insert into public.automation_rules (org_id, event_key, recipient_role) values (%L, 'ticket.created', 'customer')$q$, v_org));
  perform pg_temp.chk('anon: direct rule insert refused', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  s := pg_temp.raises(format($q$insert into public.automation_rules (org_id, event_key, recipient_role) values (%L, 'ticket.created', 'customer')$q$, v_org));
  perform pg_temp.chk('master: direct rule insert refused (only via automation_rule_save)', s like '%permission denied%', coalesce(s,'accepted'));
  s := pg_temp.raises(format($q$insert into public.automation_event_log (id, org_id, event_key, subject_type, subject_id, outcome) values (gen_random_uuid(), %L, 'ticket.created', 'ticket', gen_random_uuid(), 'no_rule')$q$, v_org));
  perform pg_temp.chk('master: cannot forge an event_log row', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_pg();

  -- ---------- an emit failure never fails the business statement ----------
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ after kill')$q$, v_org, v_cust));
  perform pg_temp.chk('business insert still succeeds', s is null, coalesce(s,'ok'));

  -- ---------- failure isolation: automation can never block a business write ----------
  -- scenario 1: the engine's own log table is unreachable, so every automation_emit raises
  alter table public.automation_event_log rename to automation_event_log_x;
  select count(*) into v_e1 from public.automation_errors where org_id = v_org;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso ticket')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 ticket insert succeeds although automation_emit raises', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (%L, %L, 'product', 10, 10, 'due')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 invoice insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (%L, %L, '__TEST_ iso lead', '9400000051', 'customer_app', 'new', 'service')$q$, v_org, v_cust));
  perform pg_temp.chk('S1 lead insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 5)$q$, v_org, v_cust));
  perform pg_temp.chk('S1 quotation insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into service_visits (org_id, ticket_id, technician_id) values (%L, (select id from service_tickets where org_id = %L and name_of_complaint = '__TEST_ iso ticket'), %L)$q$, v_org, v_org, v_tech));
  perform pg_temp.chk('S1 visit insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status) values (%L, %L, %L, %L, current_date, current_date + 30, 'active')$q$, v_org, v_cust, v_prod, v_plan));
  perform pg_temp.chk('S1 AMC contract insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into warranties (org_id, customer_id, product_id, start_date, expiry_date) values (%L, %L, %L, current_date, current_date + 30)$q$, v_org, v_cust, v_prod));
  perform pg_temp.chk('S1 warranty insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$update service_tickets set status = 'completed' where org_id = %L and name_of_complaint = '__TEST_ iso ticket'$q$, v_org));
  perform pg_temp.chk('S1 ticket status UPDATE succeeds', s is null, coalesce(s,'ok'));
  perform pg_temp.chk('S1 the business rows really exist',
    exists (select 1 from service_tickets where org_id = v_org and name_of_complaint = '__TEST_ iso ticket' and status = 'completed')
    and exists (select 1 from leads where org_id = v_org and name = '__TEST_ iso lead')
    and exists (select 1 from quotations where org_id = v_org and total = 5)
    and exists (select 1 from invoices where org_id = v_org and total = 10));
  select count(*) into v_e2 from public.automation_errors where org_id = v_org;
  perform pg_temp.chk('S1 every failure was logged to automation_errors (>= 8 emitting writes)', v_e2 - v_e1 >= 8, (v_e2 - v_e1)::text);
  perform pg_temp.chk('S1 logged sources cover ticket, invoice, lead, visit, quotation, AMC and warranty tables',
    (select count(distinct source) from public.automation_errors where org_id = v_org
        and source in ('service_tickets:INSERT','invoices:INSERT','leads:INSERT','service_visits:INSERT','quotations:INSERT','amc_contracts:INSERT','warranties:INSERT')) = 7);
  perform pg_temp.chk('S1 error rows hold an sqlstate',
    (select bool_and(sqlstate is not null) from public.automation_errors where org_id = v_org));
  alter table public.automation_event_log_x rename to automation_event_log;

  -- scenario 2: automation_emit replaced by a function that raises with a phone number and e-mail in the message
  create or replace function public.automation_emit(p_org_id uuid, p_event_key text, p_subject_type text, p_subject_id uuid,
    p_customer_id uuid default null, p_occurrence_key text default '', p_payload jsonb default '{}'::jsonb)
  returns uuid language plpgsql security definer set search_path = public as $f$
  begin raise exception 'forced failure for 9400000066 and someone@example.com'; end $f$;
  select count(*) into v_e1 from public.automation_errors where org_id = v_org;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso 2')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 ticket insert succeeds with a hostile automation_emit', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into leads (org_id, customer_id, name, mobile, source, status, kind) values (%L, %L, '__TEST_ iso lead 2', '9400000050', 'customer_app', 'new', 'service')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 lead insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into quotations (org_id, customer_id, status, total) values (%L, %L, 'open', 6)$q$, v_org, v_cust));
  perform pg_temp.chk('S2 quotation insert succeeds', s is null, coalesce(s,'ok'));
  s := pg_temp.raises(format($q$insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (%L, %L, 'product', 11, 11, 'due')$q$, v_org, v_cust));
  perform pg_temp.chk('S2 invoice insert succeeds', s is null, coalesce(s,'ok'));
  select count(*) into v_e2 from public.automation_errors where org_id = v_org;
  perform pg_temp.chk('S2 four more errors logged', v_e2 - v_e1 >= 4, (v_e2 - v_e1)::text);
  perform pg_temp.chk('S2 logged messages are scrubbed (no 7+ digit run, no e-mail)',
    not exists (select 1 from public.automation_errors where org_id = v_org and (message ~ '[0-9]{7,}' or message ~ '@'))
    and exists (select 1 from public.automation_errors where org_id = v_org and message like 'forced failure%'));
  perform pg_temp.chk('S2 the error table has no customer, mobile, name or payload column',
    not exists (select 1 from information_schema.columns where table_name = 'automation_errors' and column_name in ('mobile','customer_id','payload','name','phone')));

  -- scenario 3: the error log itself is broken too: the business write still goes through
  alter table public.automation_errors rename to automation_errors_x;
  s := pg_temp.raises(format($q$insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (%L, %L, 'paid', '__TEST_ iso 3')$q$, v_org, v_cust));
  perform pg_temp.chk('S3 ticket insert succeeds even when the error log is unavailable', s is null, coalesce(s,'ok'));
  alter table public.automation_errors_x rename to automation_errors;

  -- errors table is append-only and not client-writable; readable by ops only
  s := pg_temp.raises(format($q$delete from public.automation_errors where org_id = %L$q$, v_org));
  perform pg_temp.chk('errors: DELETE refused', s like '%append-only%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin sees no automation_errors', (select count(*) from public.automation_errors) = 0);
  s := pg_temp.raises(format($q$insert into public.automation_errors (org_id, source) values (%L, 'x')$q$, v_org));
  perform pg_temp.chk('authenticated cannot write automation_errors', s like '%permission denied%', coalesce(s,'accepted'));
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('master reads automation_errors of own org', (select count(*) from public.automation_errors) > 0);
  perform pg_temp.as_pg();

  -- ---------- real data unchanged ----------
  perform pg_temp.chk('real customers unchanged',
    fp_cust = (select md5(coalesce(string_agg(id::text||name||coalesce(mobile,''), ',' order by id),'')) from public.customers
                where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
