-- Rolled-back DB tests for Automation Phase 3 / Stage B:
--   20261029100000_automation_handoff, 20261029110000_automation_scanners_and_amc_visit_emit, 20261029120000_start_travel
-- (the dispatcher-side migration 20261029130000 has its own test). Run AFTER the three migrations (the runner concatenates
-- them in front, inside ONE transaction). Ends in RAISE; read RESULTS in the error. Throwaway __TEST_ organisation only;
-- nothing is sent (there is no sender); no real customer, number or message is touched.
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
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;

do $t$
declare
  v_org uuid; v_m uuid; v_tp1 uuid; v_tp2 uuid; v_cr uuid; v_sales uuid;
  v_tech1 uuid; v_tech2 uuid;
  v_c uuid; v_ct uuid; v_c_out uuid; v_c_nomap uuid;
  mA text := '9400000081'; mMember text := '9400000082'; mT text := '9400000083'; mOut text := '9400000084'; mOther text := '9400000085';
  v_rjob uuid; v_rfeed uuid; v_rkey uuid; v_rotw uuid;
  v_t uuid; v_t2 uuid; v_t3 uuid; v_ev uuid; v_res jsonb; v_q record;
  n int; n2 int; s text; v_ob1 int; v_ob2 int; v_fire timestamptz; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid;
  v_contract uuid; v_tk uuid; v_ap uuid; v_pid uuid;
begin
  -- ---------- schema / privileges ----------
  perform pg_temp.chk('hand-off, scanners and start_travel are not executable by anon or authenticated (travel: authenticated only)',
    not has_function_privilege('anon', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and has_function_privilege('service_role', 'public.automation_handoff_due(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_amc_expiring(timestamptz,integer[])', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_feedback(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_scan_review(timestamptz,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.start_travel(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.start_travel(uuid)', 'execute'));
  perform pg_temp.chk('no PUBLIC grant on the new functions',
    not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                 where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                   and p.proname in ('automation_handoff_due','automation_scan_amc_expiring','automation_scan_feedback','automation_scan_review',
                                     'start_travel','_automation_completed_tickets','_automation_ist_date','_trg_automation_emit_amc_visit')));
  perform pg_temp.chk('hand-off whitelist: only the three existing dispatcher ref types (amc_contract comes with the dispatcher commit)',
    (select array_agg(ref_type order by ref_type) from public.automation_handoff_ref_types) = array['invoice', 'service_ticket', 'service_visit']);
  perform pg_temp.chk('catalogue: emitters flagged for the new events',
    (select count(*) from public.automation_events where event_key in ('amc.expiring','feedback.requested','review.google_requested','amc.visit_scheduled','technician.on_the_way') and has_emitter) = 5);
  perform pg_temp.chk('travel setting default 30 and range-checked',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_default_travel_eta_minutes') = '30');
  perform pg_temp.chk('the scanners never read the ratings table (every completed service is eligible)',
    (select prosrc !~* '(from|join)[[:space:]]+(public\.)?ratings' from pg_proc where proname = 'automation_scan_review' and pronamespace = 'public'::regnamespace)
    and (select prosrc !~* '(from|join)[[:space:]]+(public\.)?ratings' from pg_proc where proname = '_automation_completed_tickets' and pronamespace = 'public'::regnamespace));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_3b') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_m := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ main', mA) returning id into v_c;
  insert into customer_members (org_id, customer_id, name, mobile, is_primary) values (v_org, v_c, '__TEST_ member', mMember, false);
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', mT, true) returning id into v_ct;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ opted', mOut) returning id into v_c_out;
  -- dispatcher: v2 ON, scope numbers, list = the main number and the flagged test number; mapping + approved mirror for the booked template
  update settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = array[mA, mT, mOut] where org_id = v_org;
  insert into whatsapp_wasi_templates (org_id, wasi_name, language, category, status) values
    (v_org, 'gvm_service_booked_en', 'en', 'utility', 'approved'),
    (v_org, 'gvm_feedback_request_en', 'en', 'utility', 'approved'),
    (v_org, 'gvm_service_booked_ta', 'ta', 'utility', 'pending');
  insert into whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map) values
    (v_org, 'gvm_service_booked', 'en', 'gvm_service_booked_en', '{"customer_name":"name","ticket_ref":"ticket_ref","complaint":"complaint"}'),
    (v_org, 'gvm_service_booked', 'ta', 'gvm_service_booked_ta', '{"customer_name":"name"}'),
    (v_org, 'gvm_feedback_request', 'en', 'gvm_feedback_request_en', '{"customer_name":"name"}');

  perform pg_temp.as_user(v_m);
  v_rjob  := public.automation_rule_save(null, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  v_rfeed := public.automation_rule_save(null, 'feedback.requested', 'customer', 'whatsapp', '{}', 'gvm_feedback_request_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  select rule_key into v_rkey from public.automation_rules where id = v_rjob;

  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked';

  -- ---------- H1: no live rule means no outbox row ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h1') returning id into v_t;
  perform pg_temp.chk('H1 setup: the live rule produced a live-mode dry_run row for the main number',
    (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'dry_run'
    and (select mode from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'live');
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'test_only');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule now test_only: nothing handed over, row untouched, no outbox row',
    (v_res ->> 'handed_over')::int = 0
    and (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'dry_run'
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'paused');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule paused: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'shadow');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 rule shadow: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);
  -- a queue row whose rule does not exist at all
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'orphan', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'ticket.created', 'ticket', v_t, v_c,
          'customer', '******0081', 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H1 a row with no current rule at all: nothing handed over',
    (v_res ->> 'handed_over')::int = 0 and (select state from public.automation_queue where idempotency_key = 'orphan') = 'dry_run');
  delete from public.automation_queue where idempotency_key = 'orphan';
  perform pg_temp.chk('H1 summary: no outbox row of any kind was created by those four runs',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1);

  -- ---------- H2: live rule, mapping, approved template, number in scope: exactly one pending row ----------
  perform pg_temp.as_user(v_m);
  v_rjob := public.automation_rule_save(v_rkey, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  select * into v_q from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked' order by created_at desc limit 1;
  perform pg_temp.chk('H2 exactly one outbox row handed over', (v_res ->> 'handed_over')::int = 1
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1, v_res::text);
  perform pg_temp.chk('H2 the row is pending (never an optimistic sent), a template row, to the MAIN number, for the ticket',
    v_q.status = 'pending' and v_q.type = 'template' and v_q.to_mobile = mA and v_q.ref_type = 'service_ticket' and v_q.ref_id = v_t
    and v_q.direction = 'outbound' and v_q.customer_id = v_c and v_q.template = 'gvm_service_booked' and v_q.wa_message_id is null);
  perform pg_temp.chk('H2 payload carries the queue id, rule key and language only (no number, no name)',
    v_q.payload ? 'automation_queue_id' and v_q.payload ->> 'language' = 'en' and v_q.payload ->> 'rule_key' = v_rkey::text
    and v_q.payload::text !~ '[0-9]{10}');
  perform pg_temp.chk('H2 queue row handed_over with the outbox id; audit handed_over',
    (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'handed_over'
    and (select outbox_id from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = v_q.id
    and exists (select 1 from public.automation_audit where subject_id = v_t and decision = 'handed_over' and detail ->> 'outbox_id' = v_q.id::text));
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H2 running it again adds nothing',
    (v_res ->> 'handed_over')::int = 0 and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  perform pg_temp.chk('H2 hand-off never wrote the optimistic status the legacy writers use',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked' and status = 'sent'));

  -- ---------- H3: dispatcher scope ----------
  update settings set wa_dispatch_v2_numbers = array[mT] where org_id = v_org;   -- main number no longer in scope
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h3') returning id into v_t2;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 number outside wa_dispatch_v2_numbers: terminal blocked_not_in_dispatch_scope, no outbox row',
    (v_res ->> 'blocked_scope')::int = 1
    and (select state from public.automation_queue where subject_id = v_t2 and rule_key = v_rkey) = 'blocked_not_in_dispatch_scope'
    and exists (select 1 from public.automation_audit where subject_id = v_t2 and decision = 'blocked_not_in_dispatch_scope')
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  update settings set wa_dispatch_v2_numbers = array[mA, mT, mOut], wa_dispatch_v2_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h3b') returning id into v_t3;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 dispatcher switched OFF: the row is held (left as it was), no outbox row',
    (v_res ->> 'handed_over')::int = 0 and (select state from public.automation_queue where subject_id = v_t3 and rule_key = v_rkey) = 'dry_run'
    and (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 1);
  update settings set wa_dispatch_v2_enabled = true where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H3 switched back on: the held row is now handed over',
    (v_res ->> 'handed_over')::int = 1 and (select state from public.automation_queue where subject_id = v_t3 and rule_key = v_rkey) = 'handed_over');

  -- ---------- H4: template mapping / approval ----------
  update customers set preferred_language = 'ta' where id = v_c;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 ta') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 Tamil mapping exists but its template is only pending in the mirror: skipped_no_template, no outbox row',
    (v_res ->> 'no_template')::int = 1 and (select state from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'skipped_no_template'
    and (select language from public.automation_queue where subject_id = v_t and rule_key = v_rkey) = 'ta');
  update customers set preferred_language = null where id = v_c;
  update whatsapp_event_templates set is_active = false where org_id = v_org and event_key = 'gvm_service_booked' and language = 'en';
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 inactive') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 inactive mapping: skipped_no_template', (v_res ->> 'no_template')::int = 1);
  update whatsapp_event_templates set is_active = true where org_id = v_org and event_key = 'gvm_service_booked' and language = 'en';
  update whatsapp_wasi_templates set status = 'paused' where org_id = v_org and wasi_name = 'gvm_service_booked_en';
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h4 paused') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H4 template not approved in the mirror: skipped_no_template', (v_res ->> 'no_template')::int = 1);
  update whatsapp_wasi_templates set status = 'approved' where org_id = v_org and wasi_name = 'gvm_service_booked_en';
  perform pg_temp.chk('H4 none of the three produced an outbox row',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_service_booked') = v_ob1 + 2);
  -- skipped rows do not count toward cooldown (S0a list extended)
  perform pg_temp.as_user(v_m);
  v_rotw := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', 'gvm_invoice_issued_en', 'en', 0, 24, null, 'live');
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c, 'i1', '{}');
  v_res := public.automation_handoff_due(now() + interval '1 minute');   -- no mapping for the invoice template: skipped_no_template
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c, 'i2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rotw;
  perform pg_temp.chk('H4 a skipped_no_template row does not start a cooldown', s = 'dry_run', coalesce(s, '-'));

  -- ---------- H5: opt-out re-checked at hand-off ----------
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_out, 'f1', '{}');
  perform public.wa_record_opt_out(v_org, mOut, 'stop');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H5 STOP after the row was queued: non-job row is skipped_opt_out at hand-off, no outbox row',
    (v_res ->> 'opted_out')::int = 1
    and (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'skipped_opt_out'
    and not exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_c_out and template = 'gvm_feedback_request'));
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c_out, 'paid', '__TEST_ h5 job') returning id into v_t;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H5 after STOP a JOB message (booked) still goes',
    (v_res ->> 'handed_over')::int = 1 and exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_c_out and template = 'gvm_service_booked'));

  -- ---------- H6: global switch, staleness ----------
  update settings set automation_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h6') returning id into v_t;
  update settings set automation_enabled = true where org_id = v_org;
  update public.automation_queue set fire_at = now() - interval '30 hours' where subject_id = v_t;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'h6', '{}');
  update public.automation_queue set fire_at = now() - interval '30 hours' where event_id = v_ev;
  v_res := public.automation_handoff_due(now());
  perform pg_temp.chk('H6 a row older than 24 hours is dropped as expired_stale, never sent late',
    (v_res ->> 'expired_stale')::int >= 1 and (select state from public.automation_queue where event_id = v_ev) = 'expired_stale'
    and exists (select 1 from public.automation_audit where event_id = v_ev and decision = 'expired_stale'));
  update settings set automation_enabled = false where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'h6b', '{}');
  update settings set automation_enabled = true where org_id = v_org;
  select count(*) into n from public.whatsapp_outbox where org_id = v_org;
  update settings set automation_enabled = false where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  select count(*) into n2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('H6 global switch OFF: nothing is handed over', n = n2 and (v_res ->> 'handed_over')::int = 0);
  update settings set automation_enabled = true where org_id = v_org;

  -- ---------- H7: only live-mode customer rows on WhatsApp ----------
  perform pg_temp.chk('H7 shadow, blocked, staff and in-app rows are never selected',
    not exists (select 1 from public.automation_queue q join public.whatsapp_outbox o on o.id = q.outbox_id
                 where q.org_id = v_org and (q.mode = 'shadow' or q.recipient_role <> 'customer' or q.channel = 'in_app' or q.state = 'blocked_not_allowlisted')));
  -- a customer-less queue row for a supported subject: terminal skipped_no_recipient
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'nocust', v_rjob, v_rkey, 1, gen_random_uuid(), 'ticket.created', 'ticket', gen_random_uuid(), null,
          'customer', null, 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H7 a row with no customer: skipped_no_recipient, no outbox row',
    (select state from public.automation_queue where idempotency_key = 'nocust') = 'skipped_no_recipient');
  -- unsupported subject (amc_contract has no dispatcher ref type yet): untouched
  insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id,
         customer_id, recipient_role, recipient_masked, channel, template_name, language, fire_at, state, is_test, mode, message_class)
  values (v_org, 'amc-unsupported', v_rjob, v_rkey, 1, gen_random_uuid(), 'ticket.created', 'amc_contract', gen_random_uuid(), v_c,
          'customer', '******0081', 'whatsapp', 'gvm_service_booked_en', 'en', now() - interval '1 minute', 'dry_run', false, 'live', 'job');
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H7 a subject type the dispatcher cannot resolve yet is left untouched',
    (select state from public.automation_queue where idempotency_key = 'amc-unsupported') = 'dry_run');
  delete from public.automation_queue where idempotency_key in ('nocust', 'amc-unsupported');

  -- ---------- H8: main customer's number only ----------
  perform pg_temp.chk('H8 no outbox row from automation ever went to the family member number',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and to_mobile = mMember));

  -- ---------- H9: test subject and test mode ----------
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = array[mT] where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h9 real') returning id into v_t;
  -- emit already blocked it (not allow-listed); a row queued BEFORE test mode was switched on is blocked at hand-off
  update settings set wa_test_mode_enabled = false where org_id = v_org;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ h9 queued') returning id into v_t2;
  update settings set wa_test_mode_enabled = true where org_id = v_org;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H9 test mode ON, number not on the list: blocked_not_allowlisted at hand-off, no outbox row',
    (v_res ->> 'blocked_allow_list')::int >= 1
    and (select state from public.automation_queue where subject_id = v_t2 and rule_key = v_rkey) = 'blocked_not_allowlisted');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_ct, 'paid', '__TEST_ h9 flagged') returning id into v_t3;
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('H9 the flagged test customer (its own number is on the list) is handed over',
    exists (select 1 from public.whatsapp_outbox where org_id = v_org and customer_id = v_ct and to_mobile = mT and status = 'pending'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}' where org_id = v_org;

  -- ---------- H10: queue context is small and non-personal ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c, 'ctx',
            jsonb_build_object('mobile', mMember, 'days_left', 7, 'eta_minutes', 30, 'name', 'Someone', 'ticket_type', 'paid'));
  perform pg_temp.chk('H10 only whitelisted, non-personal keys are kept in the queue context',
    (select context from public.automation_queue where event_id = v_ev and rule_key = v_rkey) = '{"days_left": 7, "eta_minutes": 30, "ticket_type": "paid"}'::jsonb);

  -- ---------- scanners ----------
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ scan', '9400000086') returning id into v_c_nomap;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 1, 3000, 1) returning id into v_plan;
  perform pg_temp.as_user(v_m);
  perform public.automation_rule_save(null, 'amc.expiring', 'customer', 'whatsapp', '{}', 'gvm_amc_expiring_en', 'en', 0, 0, null, 'live');
  perform public.automation_rule_save(null, 'review.google_requested', 'customer', 'whatsapp', '{}', 'gvm_google_review_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  select v_org, v_c_nomap, v_prod, v_plan, current_date - 300, public._automation_ist_date(now()) + d, 'active' from unnest(array[30, 15, 7, 10, 1]) d;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, cancelled_at, cancel_reason)
  values (v_org, v_c_nomap, v_prod, v_plan, current_date - 300, public._automation_ist_date(now()) + 30, 'active', now(), '__TEST_ cancelled');
  v_res := public.automation_scan_amc_expiring(now());
  perform pg_temp.chk('SCAN amc.expiring emits exactly the 30, 15 and 7 day windows (not 10, not 1, not a cancelled contract)',
    (v_res ->> 'emitted')::int >= 3
    and (select count(*) from public.automation_event_log where org_id = v_org and event_key = 'amc.expiring') = (v_res ->> 'emitted')::int
    and (select array_agg(occurrence_key order by occurrence_key) from public.automation_event_log where org_id = v_org and event_key = 'amc.expiring')
        = array['expiring@15', 'expiring@30', 'expiring@7'], v_res::text);
  perform pg_temp.chk('SCAN the queue row carries days_left and a window that ends tomorrow (a 7-day reminder is not late-sent)',
    (select (context ->> 'days_left')::int from public.automation_queue where event_key = 'amc.expiring' and org_id = v_org and detail ->> 'language' = 'en' and context ->> 'days_left' = '7' limit 1) = 7
    and (select (context ->> 'window_end')::timestamptz from public.automation_queue where event_key = 'amc.expiring' and org_id = v_org and context ->> 'days_left' = '7' limit 1)
        > now());
  select count(*) into n from public.automation_queue where org_id = v_org and event_key = 'amc.expiring';
  v_res := public.automation_scan_amc_expiring(now());
  select count(*) into n2 from public.automation_queue where org_id = v_org and event_key = 'amc.expiring';
  perform pg_temp.chk('SCAN running amc.expiring again adds no queue row (idempotent)', n = n2, n::text);
  perform pg_temp.chk('SCAN simulated p_now: a day later the 30-day contract is a 29-day contract, nothing new in the 30 window',
    (public.automation_scan_amc_expiring(now() + interval '1 day') ->> 'emitted')::int >= 0);

  -- completed tickets: 25 h ago (eligible), 5 h ago (too recent), 6 days ago (outside the lookback)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 25h', 'completed') returning id into v_t;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t, v_tech1, now() - interval '25 hours');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 5h', 'completed') returning id into v_t2;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t2, v_tech1, now() - interval '5 hours');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, status) values (v_org, v_c_nomap, 'paid', '__TEST_ done 6d', 'completed') returning id into v_t3;
  insert into service_visits (org_id, ticket_id, technician_id, timer_end) values (v_org, v_t3, v_tech1, now() - interval '6 days');
  v_res := public.automation_scan_feedback(now());
  perform pg_temp.chk('SCAN feedback: only the ticket completed 25 h ago',
    exists (select 1 from public.automation_event_log where event_key = 'feedback.requested' and subject_id = v_t)
    and not exists (select 1 from public.automation_event_log where event_key = 'feedback.requested' and subject_id in (v_t2, v_t3)));
  v_res := public.automation_scan_review(now());
  perform pg_temp.chk('SCAN review: same selection, every completed service (no rating, rule or staff condition)',
    exists (select 1 from public.automation_event_log where event_key = 'review.google_requested' and subject_id = v_t)
    and not exists (select 1 from public.automation_event_log where event_key = 'review.google_requested' and subject_id in (v_t2, v_t3)));
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key in ('feedback.requested', 'review.google_requested');
  perform public.automation_scan_feedback(now());
  perform public.automation_scan_review(now());
  perform pg_temp.chk('SCAN re-running the scanners logs events again but queues nothing new',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_t and event_key in ('feedback.requested', 'review.google_requested')) <= 2);
  perform pg_temp.chk('SCAN scanners are dry-run: no outbox row was created by them',
    not exists (select 1 from public.whatsapp_outbox where org_id = v_org and template in ('gvm_amc_expiring', 'gvm_google_review', 'gvm_feedback_request') and customer_id = v_c_nomap));

  -- AMC visit emit
  select count(*) into n from public.automation_event_log where org_id = v_org and event_key = 'amc.visit_scheduled';
  perform pg_temp.as_user(v_m);
  v_pid := (public.sell_amc_plan(v_org, v_c_nomap, v_prod, v_plan, current_date + 5, null, null) ->> 'contract_id')::uuid;
  perform pg_temp.as_pg();
  select count(*) into n2 from public.automation_event_log where org_id = v_org and event_key = 'amc.visit_scheduled' and subject_id = v_pid;
  perform pg_temp.chk('VISIT a sale emits amc.visit_scheduled exactly ONCE for the contract, however many visits it generated',
    n2 = 1 and (select count(*) from public.service_tickets where contract_id = v_pid) >= 1, n2::text);
  perform pg_temp.chk('VISIT the announced visit is the nearest one (its ticket has the earliest scheduled appointment)',
    (select e.occurrence_key from public.automation_event_log e where e.event_key = 'amc.visit_scheduled' and e.subject_id = v_pid)
      = 'visit@' || (select t.id::text from public.service_tickets t join public.appointments a on a.ticket_id = t.id
                      where t.contract_id = v_pid order by a.scheduled_at, a.created_at limit 1));
  perform pg_temp.chk('VISIT the event carries visit_date and days_left, and the subject is the contract',
    exists (select 1 from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_pid and 'visit_date' = any (payload_keys) and 'days_left' = any (payload_keys)));
  -- ordering rule, built by hand on a fresh contract: a later visit and an equal-date visit stay silent; an earlier visit
  -- inserted afterwards is the new nearest and is announced (the generators insert in date order, so this does not happen in practice)
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_c, v_prod, v_plan, current_date, current_date + 365, 'active') returning id into v_contract;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit A', v_contract) returning id into v_t;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t, now() + interval '10 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT first visit of a contract is announced',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit B', v_contract) returning id into v_t2;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t2, now() + interval '20 days', 'datetime', 'scheduled');
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit C', v_contract) returning id into v_t3;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t3, (select scheduled_at from appointments where ticket_id = v_t), 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT a later visit and an equal-date visit stay silent',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 1);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, contract_id) values (v_org, v_c, 'amc', '__TEST_ visit D', v_contract) returning id into v_t3;
  insert into appointments (org_id, ticket_id, scheduled_at, mode, status) values (v_org, v_t3, now() + interval '5 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT an earlier visit inserted afterwards is the new nearest and is announced',
    (select count(*) from public.automation_event_log where event_key = 'amc.visit_scheduled' and subject_id = v_contract) = 2);
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ plain ticket') returning id into v_t;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t, v_tech1, now() + interval '2 days', 'datetime', 'scheduled');
  perform pg_temp.chk('VISIT an ordinary (non-AMC) appointment emits no amc.visit_scheduled',
    not exists (select 1 from public.automation_event_log where event_key = 'amc.visit_scheduled' and occurrence_key = 'visit@' || v_t::text));

  -- ---------- start_travel ----------
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel') returning id into v_tk;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_tk, v_tech1, now() + interval '3 hours', 'datetime', 'scheduled') returning id into v_ap;
  update service_tickets set status = 'assigned' where id = v_tk;
  update settings set automation_default_travel_eta_minutes = 45 where org_id = v_org;
  perform pg_temp.as_user(v_tp2);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL another technician is refused', s like '%not assigned to you%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_m);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL master (not a technician) is refused', s like '%only a technician%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL customer role is refused', s like '%only a technician%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_tk));
  perform pg_temp.chk('TRAVEL anon is refused', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL nothing was stamped by the refused calls',
    (select travel_started_at from public.appointments where id = v_ap) is null
    and not exists (select 1 from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk));
  perform pg_temp.as_user(v_tp1);
  v_res := public.start_travel(v_tk);
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL the assigned technician starts travel: stamped, not already_started',
    (v_res ->> 'already_started')::boolean = false and (select travel_started_at from public.appointments where id = v_ap) is not null);
  perform pg_temp.chk('TRAVEL exactly one technician.on_the_way event, with the master-set estimate',
    (select count(*) from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk) = 1
    and exists (select 1 from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk and 'eta_minutes' = any (payload_keys)));
  perform pg_temp.as_user(v_tp1);
  v_res := public.start_travel(v_tk);
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL a repeat tap changes nothing and emits nothing',
    (v_res ->> 'already_started')::boolean
    and (select count(*) from public.automation_event_log where event_key = 'technician.on_the_way' and subject_id = v_tk) = 1);
  -- a live rule for on_the_way (quiet-hours exempt): fire_at is now, even in quiet hours; context holds the eta
  perform pg_temp.as_user(v_m);
  v_rotw := public.automation_rule_save(null, 'technician.on_the_way', 'customer', 'whatsapp', '{}', 'gvm_technician_on_the_way_en', 'en', 0, 0, null, 'live');
  perform pg_temp.as_pg();
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel 2') returning id into v_t2;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t2, v_tech1, now() + interval '6 hours', 'datetime', 'scheduled');
  update service_tickets set status = 'assigned' where id = v_t2;
  perform pg_temp.as_user(v_tp1);
  perform public.start_travel(v_t2);
  perform pg_temp.as_pg();
  select fire_at, context into v_q from public.automation_queue where subject_id = v_t2 and event_key = 'technician.on_the_way';
  perform pg_temp.chk('TRAVEL queue row: not held by quiet hours, eta_minutes = 45 in the context',
    v_q.fire_at < now() + interval '1 minute' and (v_q.context ->> 'eta_minutes')::int = 45);
  -- job state guards
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel open') returning id into v_t3;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t3, v_tech1, now() + interval '9 hours', 'datetime', 'scheduled');
  perform pg_temp.as_user(v_tp1);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_t3));
  perform pg_temp.as_pg();
  perform pg_temp.chk('TRAVEL a job that is not assigned (still open) cannot start travel', s like '%only be started for an assigned job%', coalesce(s, 'accepted'));
  update service_tickets set status = 'in_progress' where id = v_tk;
  perform pg_temp.chk('TRAVEL settings estimate is range-checked',
    pg_temp.raises(format($q$update settings set automation_default_travel_eta_minutes = 0 where org_id = %L$q$, v_org)) like '%check constraint%');

  -- failure isolation: the engine is broken, the stamp still commits and the error is logged
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ travel iso') returning id into v_t;
  insert into appointments (org_id, ticket_id, technician_id, scheduled_at, mode, status) values (v_org, v_t, v_tech2, now() + interval '3 hours', 'datetime', 'scheduled') returning id into v_ap;
  update service_tickets set status = 'assigned' where id = v_t;
  alter table public.automation_event_log rename to automation_event_log_x;
  perform pg_temp.as_user(v_tp2);
  s := pg_temp.raises(format($q$select public.start_travel(%L)$q$, v_t));
  perform pg_temp.as_pg();
  alter table public.automation_event_log_x rename to automation_event_log;
  perform pg_temp.chk('TRAVEL an automation failure does not undo the stamp, and it is logged',
    s is null and (select travel_started_at from public.appointments where id = v_ap) is not null
    and exists (select 1 from public.automation_errors where org_id = v_org and source = 'start_travel'), coalesce(s, 'ok'));

  -- ---------- nothing sent by the engine itself ----------
  perform pg_temp.chk('wa_dispatch_v2_enabled for the real organisation is untouched',
    not exists (select 1 from settings s join organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' and s.wa_dispatch_v2_enabled));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
