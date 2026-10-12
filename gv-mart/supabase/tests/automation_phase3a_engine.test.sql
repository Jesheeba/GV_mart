-- Rolled-back DB tests for Automation Phase 3 / Stage A:
--   20261018100000_customer_comm_prefs, 20261018110000_customer_preferred_language, 20261018120000_automation_phase3a_engine.
-- Run AFTER the three migrations (the runner concatenates them in front, inside ONE transaction; the Phase 2 migration is
-- already live). Ends in RAISE; read RESULTS in the error. Throwaway __TEST_ organisations only; nothing is sent (there is no
-- sender); no real customer, number or message is touched.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_lang text default 'en', p_active boolean default true) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active, language) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, p_active, p_lang)
    on conflict (id) do update set role = excluded.role, is_active = excluded.is_active, org_id = excluded.org_id, language = excluded.language;
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
  v_org uuid; v_org2 uuid; v_m1 uuid; v_m2 uuid; v_m_off uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_login_ta uuid;
  v_c1 uuid; v_c5 uuid; v_c6 uuid; v_c2 uuid; v_c_ta uuid; v_c_login uuid; v_c_plain uuid; v_ct uuid;
  v_mob1 text := '9400000061'; v_member text := '9400000062'; v_mob2 text := '9400000063'; v_mobta text := '9400000064';
  v_rfeed uuid; v_rjob uuid; v_rinv uuid; v_rrev uuid; v_rshadow uuid; v_rsales uuid; v_rexempt uuid; v_rexempt2 uuid; v_rkey uuid;
  v_ev uuid; v_ev2 uuid; s text; n int; n2 int; rec record; v_fire timestamptz; v_ob1 int; v_ob2 int; v_t uuid;
  v_start time; v_end time; v_local time; v_q uuid; v_cnt int; v_lead uuid; v_res jsonb;
begin
  -- ---------- schema / privileges ----------
  perform pg_temp.chk('new tables exist with RLS',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
       and c.relname in ('customer_comm_prefs','customer_comm_pref_events','automation_template_classes')) = 3);
  perform pg_temp.chk('wa_record_opt_out / release / helpers: not executable by anon or authenticated',
    not has_function_privilege('anon', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and has_function_privilege('service_role', 'public.wa_record_opt_out(uuid,text,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.automation_release_deferred(timestamptz)', 'execute')
    and not has_function_privilege('anon', 'public.automation_release_deferred(timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_next_allowed(timestamptz,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_is_opted_out(uuid,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public._automation_audit_row(uuid,uuid,text,text,uuid,uuid,uuid,integer,text,uuid,text,text,text,text,jsonb,boolean,text)', 'execute')
    and has_function_privilege('authenticated', 'public.set_customer_comm_pref(uuid,boolean,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.set_customer_comm_pref(uuid,boolean,boolean)', 'execute'));
  perform pg_temp.chk('no PUBLIC grant on any new function',
    not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                  and (p.proname like '\_automation\_%' or p.proname in ('wa_record_opt_out','set_customer_comm_pref','automation_release_deferred','automation_emit'))));
  perform pg_temp.chk('no client write privilege on the new tables; anon cannot read them',
    not exists (select 1 from unnest(array['customer_comm_prefs','customer_comm_pref_events','automation_template_classes']) t,
                     unnest(array['anon','authenticated']) r, unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) pr
                where has_table_privilege(r, 'public.' || t, pr))
    and not exists (select 1 from unnest(array['customer_comm_prefs','customer_comm_pref_events','automation_template_classes']) t
                where has_table_privilege('anon', 'public.' || t, 'SELECT')));
  perform pg_temp.chk('catalogue: exempt events and the review floor',
    (select quiet_hours_exempt from public.automation_events where event_key = 'technician.on_the_way')
    and (select quiet_hours_exempt from public.automation_events where event_key = 'otp.issued')
    and not (select quiet_hours_exempt from public.automation_events where event_key = 'ticket.created')
    and (select min_cooldown_hours from public.automation_events where event_key = 'review.google_requested') = 2160);
  perform pg_temp.chk('settings defaults: quiet 21:00-08:00, cap 3',
    (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_non_job_daily_cap') = '3'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_quiet_start') like '%21:00%'
    and (select column_default from information_schema.columns where table_name = 'settings' and column_name = 'automation_quiet_end') like '%08:00%');
  perform pg_temp.chk('classification table: job vs non-job seeds',
    (select message_class from public.automation_template_classes where template_base = 'gvm_invoice_issued') = 'job'
    and (select message_class from public.automation_template_classes where template_base = 'gvm_feedback_request') = 'non_job'
    and (select message_class from public.automation_template_classes where template_base = 'gvm_google_review') = 'non_job'
    and (select message_class from public.automation_template_classes where template_base = 'gvm_amc_expiring') = 'non_job'
    and public._automation_class('gvm_service_booked_ta', null, 'non_job') = 'job'
    and public._automation_class('unknown_tpl_en', null, null) = 'non_job'
    and public._automation_class('gvm_service_booked_en', 'non_job', 'job') = 'non_job');
  perform pg_temp.chk('S2 backfill: no real customer with a login language is left without preferred_language',
    not exists (select 1 from public.customers c join public.profiles p on p.id = c.primary_profile_id
                 where p.language in ('en','ta') and c.preferred_language is null
                   and c.org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_3a') returning id into v_org;
  insert into organizations (name) values ('__TEST_automation_3a_nomaster') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_m1 := pg_temp.mkuser('master', v_org);
  v_m2 := pg_temp.mkuser('master', v_org);
  v_m_off := pg_temp.mkuser('master', v_org, 'en', false);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_login_ta := pg_temp.mkuser('customer', v_org, 'ta');
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ main', v_mob1) returning id into v_c1;
  insert into customer_members (org_id, customer_id, name, mobile, is_primary) values (v_org, v_c1, '__TEST_ member', v_member, false);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ second', v_mob2) returning id into v_c2;
  insert into customers (org_id, name, mobile, preferred_language) values (v_org, '__TEST_ tamil pref', v_mobta, 'ta') returning id into v_c_ta;
  insert into customers (org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_ login ta', '9400000065', v_login_ta) returning id into v_c_login;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ plain', '9400000066') returning id into v_c_plain;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000067', true) returning id into v_ct;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ cap', '9400000068') returning id into v_c5;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ review', '9400000069') returning id into v_c6;

  perform pg_temp.chk('S2 preferred_language accepts en/ta/null and refuses anything else',
    pg_temp.raises(format($q$update customers set preferred_language = 'fr' where id = %L$q$, v_c1)) like '%check constraint%'
    and pg_temp.raises(format($q$update customers set preferred_language = 'en' where id = %L$q$, v_c1)) is null
    and pg_temp.raises(format($q$update customers set preferred_language = null where id = %L$q$, v_c1)) is null);

  -- rules (master saves)
  perform pg_temp.as_user(v_m1);
  v_rfeed := public.automation_rule_save(null, 'feedback.requested', 'customer', 'whatsapp', '{}', 'gvm_feedback_request_en', 'en', 0, 0, null, 'live');
  v_rjob  := public.automation_rule_save(null, 'ticket.created', 'customer', 'whatsapp', '{}', 'gvm_service_booked_en', 'en', 0, 0, null, 'live');
  v_rinv  := public.automation_rule_save(null, 'invoice.issued', 'customer', 'whatsapp', '{}', 'gvm_invoice_issued_en', 'en', 0, 0, null, 'live');
  v_rrev  := public.automation_rule_save(null, 'review.google_requested', 'customer', 'whatsapp', '{}', 'gvm_google_review_en', 'en', 0, 0, null, 'live');
  v_rsales := public.automation_rule_save(null, 'lead.created', 'sales', 'in_app', '{}', null, null, 0, 0, null, 'live');
  perform pg_temp.chk('rule save accepts the new knobs and the shadow status; an invalid class is refused',
    public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', 'gvm_amc_welcome_en', 'en', 0, 0, null, 'shadow', null, null, 'job', false, 24) is not null
    and pg_temp.raises($q$select public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'live', null, null, 'urgent')$q$) like '%check constraint%'
    and pg_temp.raises($q$select public.automation_rule_save(null, 'amc.joined', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'bogus')$q$) like '%check constraint%');
  perform pg_temp.as_pg();
  select count(*) into n from public.automation_audit where org_id = v_org and decision = 'config_changed';
  perform pg_temp.chk('rule saves are audited', n >= 6, n::text);

  select count(*) into v_ob1 from public.whatsapp_outbox where org_id = v_org;

  -- ---------- S7: main customer's mobile only ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('mobile', v_member));
  select recipient_masked into s from public.automation_queue where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S7 customer rule uses the main number even when the payload carries a family member number',
    s = '******' || right(v_mob1, 4) and s <> '******' || right(v_member, 4), coalesce(s, 'none'));
  perform pg_temp.chk('S7 no queue or audit row ever carries the member number',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked = '******' || right(v_member, 4))
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked = '******' || right(v_member, 4)));

  -- ---------- S2: language order ----------
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_ta, 'created', '{}');
  perform pg_temp.chk('S2 preferred_language ta wins over the rule language en',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'ta');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_login, 'created', '{}');
  perform pg_temp.chk('S2 no preference: the login language (ta) is used',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'ta');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_plain, 'created', '{}');
  perform pg_temp.chk('S2 nothing set: the rule language (en)',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'en');
  update customers set preferred_language = 'en' where id = v_c_login;
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c_login, 'created', '{}');
  perform pg_temp.chk('S2 preferred en beats a ta login',
    (select language from public.automation_queue where event_id = v_ev and rule_id = v_rjob) = 'en');
  perform pg_temp.chk('S2 empty everywhere: English',
    public._automation_language(v_org, v_c_plain, null) = 'en');

  -- ---------- S3: STOP / STOP ALL / START ----------
  perform pg_temp.chk('S3 before any STOP: non-job and job both pass',
    not public._automation_is_opted_out(v_org, v_mob2, 'non_job') and not public._automation_is_opted_out(v_org, v_mob2, 'job'));
  perform public.wa_record_opt_out(v_org, '+91 ' || v_mob2, 'stop', 'whatsapp');
  perform pg_temp.chk('S3 STOP: non-job blocked, job (and invoices) continue',
    public._automation_is_opted_out(v_org, v_mob2, 'non_job') and not public._automation_is_opted_out(v_org, v_mob2, 'job'));
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'f', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rfeed;
  perform pg_temp.chk('S3 engine: feedback (non-job) after STOP -> skipped_opt_out', s = 'skipped_opt_out', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c2, 'c', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S3 engine: booking (job) after STOP -> still dry_run', s = 'dry_run', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c2, 'i', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rinv;
  perform pg_temp.chk('S3 engine: invoice after STOP -> still dry_run', s = 'dry_run', coalesce(s, '-'));
  perform public.wa_record_opt_out(v_org, v_mob2, 'stop_all');
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c2, 'c2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S3 STOP ALL: even job messages are skipped_opt_out', s = 'skipped_opt_out', coalesce(s, '-'));
  perform public.wa_record_opt_out(v_org, v_mob2, 'stop');
  perform pg_temp.chk('S3 a later STOP does not clear STOP ALL',
    (select opt_out_all from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2));
  perform public.wa_record_opt_out(v_org, v_mob2, 'start');
  perform pg_temp.chk('S3 START clears both',
    not (select opt_out_all or opt_out_non_job from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2)
    and not public._automation_is_opted_out(v_org, v_mob2, 'non_job'));
  perform pg_temp.chk('S3 history: four events, last four digits only, linked customer set',
    (select count(*) from public.customer_comm_pref_events where org_id = v_org and mobile_last4 = right(v_mob2, 4)) = 4
    and not exists (select 1 from public.customer_comm_pref_events where org_id = v_org and mobile_last4 !~ '^[0-9]{4}$')
    and (select customer_id from public.customer_comm_prefs where org_id = v_org and mobile_key = v_mob2) = v_c2);
  rec := null;
  select (public.wa_record_opt_out(v_org, '9400000099', 'stop') ->> 'opt_out_non_job')::boolean as ok into rec;
  perform pg_temp.chk('S3 an unknown number (not a customer) can opt out too',
    rec.ok and (select customer_id is null from public.customer_comm_prefs where org_id = v_org and mobile_key = '9400000099'));
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'unsubscribe')$q$, v_org));
  perform pg_temp.chk('S3 unknown action refused', s like '%unknown action%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '12345', 'stop')$q$, v_org));
  perform pg_temp.chk('S3 short number refused', s like '%10-digit%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$update public.customer_comm_pref_events set action = 'start'$q$);
  perform pg_temp.chk('S3 history is append-only', s like '%append-only%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'start')$q$, v_org));
  perform pg_temp.chk('S3 anon cannot call wa_record_opt_out', s like '%permission denied%', coalesce(s, 'accepted'));
  s := pg_temp.raises($q$select * from public.customer_comm_prefs$q$);
  perform pg_temp.chk('S3 anon cannot read the opt-out record', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select public.wa_record_opt_out(%L, '9400000099', 'start')$q$, v_org));
  perform pg_temp.chk('S3 authenticated staff cannot call wa_record_opt_out', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.chk('S3 sales_admin cannot read the record', (select count(*) from public.customer_comm_prefs) = 0);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 sales_admin cannot set a preference', s like '%only master or operations%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 customer role cannot set a preference', s like '%only master or operations%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select public.set_customer_comm_pref(%L, true, false)$q$, v_c1));
  perform pg_temp.chk('S3 operations can set a preference and reads the record',
    s is null and (select opt_out_non_job from public.customer_comm_prefs where mobile_key = v_mob1)
    and (select count(*) from public.customer_comm_prefs) > 0);
  perform pg_temp.as_pg();
  perform public.wa_record_opt_out(v_org, v_mob1, 'start');

  -- ---------- S0a / S0b: shadow rows never count, and never suppress the live send ----------
  perform pg_temp.as_user(v_m1);
  v_rshadow := public.automation_rule_save(null, 'quotation.converted', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 24, 1, 'shadow');
  perform pg_temp.as_pg();
  select rule_key into v_rkey from public.automation_rules where id = v_rshadow;
  v_t := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_t, v_c1, 'converted', '{}');
  perform pg_temp.chk('S0 shadow rule writes a shadow-mode row',
    (select mode from public.automation_queue where event_id = v_ev) = 'shadow');
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', gen_random_uuid(), v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0 inside shadow mode cooldown/max-fires still simulate (second subject skipped)',
    s in ('skipped_cooldown', 'skipped_max_fires'), coalesce(s, '-'));
  perform pg_temp.as_user(v_m1);
  v_rshadow := public.automation_rule_save(v_rkey, 'quotation.converted', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 24, 1, 'live');
  perform pg_temp.as_pg();
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_lead, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0a promoted to live: the earlier SHADOW row does not trigger cooldown or max-fires', s = 'dry_run', coalesce(s, '-'));
  perform pg_temp.chk('S0a that row is mode live',
    (select mode from public.automation_queue where event_id = v_ev and rule_key = v_rkey) = 'live');
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_t, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0b the SAME occurrence that was shadowed is not a duplicate for the live rule (keys differ by mode)',
    s in ('dry_run', 'skipped_cooldown', 'skipped_max_fires') and s <> 'skipped_duplicate', coalesce(s, '-'));
  perform pg_temp.chk('S0b live keys end in |live|- and shadow keys in |shadow|-',
    exists (select 1 from public.automation_queue where org_id = v_org and rule_key = v_rkey and idempotency_key like '%|shadow|-')
    and exists (select 1 from public.automation_queue where org_id = v_org and rule_key = v_rkey and idempotency_key like '%|live|-'));
  v_ev := public.automation_emit(v_org, 'quotation.converted', 'quotation', v_lead, v_c1, 'converted', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_key = v_rkey;
  perform pg_temp.chk('S0b a true replay inside live mode is skipped_duplicate', s = 'skipped_duplicate', coalesce(s, '-'));

  -- ---------- S1: master fallback ----------
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead, null, 'created', jsonb_build_object('kind', 'service'));
  select count(*) into n from public.automation_queue where event_id = v_ev and rule_id = v_rsales;
  perform pg_temp.chk('S1 no sales person: one row per ACTIVE master (2), none for the inactive master',
    n = 2
    and exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m1)
    and exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m2)
    and not exists (select 1 from public.automation_queue where event_id = v_ev and recipient_profile_id = v_m_off), n::text);
  perform pg_temp.chk('S1 fallback is recorded in the audit detail',
    (select count(*) from public.automation_audit where event_id = v_ev and detail ->> 'recipient_fallback' = 'master') = 2);
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), null, 'created', jsonb_build_object('sales_person_id', v_sales));
  perform pg_temp.chk('S1 with a sales person, only that person (no fallback)',
    (select count(*) from public.automation_queue where event_id = v_ev and rule_id = v_rsales) = 1
    and (select recipient_profile_id from public.automation_queue where event_id = v_ev and rule_id = v_rsales) = v_sales
    and not exists (select 1 from public.automation_audit where event_id = v_ev and detail ? 'recipient_fallback'));
  perform pg_temp.chk('S1 master fan-out replay is idempotent per master',
    (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_lead) = 2
    and (public.automation_emit(v_org, 'lead.created', 'lead', v_lead, null, 'created', jsonb_build_object('kind', 'service')) is not null)
    and (select count(*) from public.automation_queue where org_id = v_org and subject_id = v_lead) = 2);
  -- an organisation with no active master and no sales person: nobody to notify
  update public.profiles set is_active = false where org_id = v_org and role = 'master';
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), null, 'created', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rsales;
  perform pg_temp.chk('S1 no active master at all -> skipped_no_recipient', s = 'skipped_no_recipient', coalesce(s, '-'));
  update public.profiles set is_active = true where id in (v_m1, v_m2);

  -- ---------- S4: quiet hours ----------
  perform pg_temp.chk('S4 helper: 21:00 IST rolls to 08:00 next day; 20:59 unchanged; 03:00 rolls to 08:00 same day; 08:00 unchanged',
    public._automation_next_allowed('2026-01-10 21:00:00+05:30', v_org) = '2026-01-11 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 20:59:59+05:30', v_org) = '2026-01-10 20:59:59+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 03:00:00+05:30', v_org) = '2026-01-10 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 08:00:00+05:30', v_org) = '2026-01-10 08:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 23:30:00+05:30', v_org) = '2026-01-11 08:00:00+05:30'::timestamptz);
  update settings set automation_quiet_start = '13:00', automation_quiet_end = '14:00' where org_id = v_org;
  perform pg_temp.chk('S4 helper follows the setting (non-wrapping window)',
    public._automation_next_allowed('2026-01-10 13:30:00+05:30', v_org) = '2026-01-10 14:00:00+05:30'::timestamptz
    and public._automation_next_allowed('2026-01-10 21:30:00+05:30', v_org) = '2026-01-10 21:30:00+05:30'::timestamptz);
  -- make "now" fall inside quiet hours: window = [local now - 1h, local now + 1h)
  v_local := (now() at time zone 'Asia/Kolkata')::time;
  update settings set automation_quiet_start = (v_local - interval '1 hour')::time, automation_quiet_end = (v_local + interval '1 hour')::time where org_id = v_org;
  perform pg_temp.as_user(v_m1);
  v_rexempt := public.automation_rule_save(null, 'technician.on_the_way', 'customer', 'whatsapp', '{}', 'gvm_technician_on_the_way_en', 'en', 0, 0, null, 'live');
  v_rexempt2 := public.automation_rule_save(null, 'ticket.assigned', 'customer', 'whatsapp', '{}', 'gvm_technician_assigned_en', 'en', 0, 0, null, 'live', null, null, null, false);
  perform pg_temp.as_pg();
  v_ev := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c1, 'created', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rjob;
  perform pg_temp.chk('S4 a held job message is pushed to the end of the quiet window (about +1h)',
    v_fire > now() + interval '50 minutes' and v_fire < now() + interval '70 minutes', (v_fire - now())::text);
  v_ev := public.automation_emit(v_org, 'technician.on_the_way', 'ticket', gen_random_uuid(), v_c1, 'otw', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rexempt;
  perform pg_temp.chk('S4 on_the_way is exempt: not held', v_fire < now() + interval '1 minute', (v_fire - now())::text);
  v_ev := public.automation_emit(v_org, 'ticket.assigned', 'ticket', gen_random_uuid(), v_c1, 'assigned', '{}');
  select fire_at into v_fire from public.automation_queue where event_id = v_ev and rule_id = v_rexempt2;
  perform pg_temp.chk('S4 a rule with respect_quiet_hours = false is not held', v_fire < now() + interval '1 minute', (v_fire - now())::text);
  update settings set automation_quiet_start = '21:00', automation_quiet_end = '08:00' where org_id = v_org;

  -- ---------- S5: daily cap for non-job only ----------
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c5, 'f' || n, '{}');
  end loop;
  perform pg_temp.chk('S5 three non-job messages in a day all pass',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and rule_id = v_rfeed and state = 'dry_run') = 3);
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c5, 'f4', '{}');
  select state, fire_at, expires_at into rec from public.automation_queue where event_id = v_ev and rule_id = v_rfeed;
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rfeed;
  perform pg_temp.chk('S5 the fourth non-job message is deferred with an expiry', rec.state = 'deferred' and s = 'deferred_daily_cap' and rec.expires_at is not null, coalesce(rec.state, '-') || '/' || coalesce(s, '-'));
  perform pg_temp.chk('S5 deferred to the next IST day at the end of quiet hours (08:00)',
    (rec.fire_at at time zone 'Asia/Kolkata')::time = '08:00'
    and (rec.fire_at at time zone 'Asia/Kolkata')::date > (now() at time zone 'Asia/Kolkata')::date - 1
    and rec.fire_at > now());
  v_q := (select id from public.automation_queue where event_id = v_ev and rule_id = v_rfeed);
  -- job messages and invoices are never counted or deferred, even over the cap
  for n in 1..4 loop
    v_ev2 := public.automation_emit(v_org, 'ticket.created', 'ticket', gen_random_uuid(), v_c5, 'jc' || n, '{}');
    v_ev2 := public.automation_emit(v_org, 'invoice.issued', 'invoice', gen_random_uuid(), v_c5, 'ji' || n, '{}');
  end loop;
  perform pg_temp.chk('S5 job and invoice messages are never deferred by the cap',
    not exists (select 1 from public.automation_queue where org_id = v_org and customer_id = v_c5 and message_class = 'job' and state = 'deferred')
    and (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and rule_id in (v_rjob, v_rinv) and state = 'dry_run') >= 8);
  perform pg_temp.chk('S5 job messages do not use up the non-job allowance (still exactly 3 non-job today)',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c5 and message_class = 'non_job' and state = 'dry_run') = 3);
  -- another customer is unaffected
  v_ev2 := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_plain, 'f1', '{}');
  perform pg_temp.chk('S5 the cap is per customer', (select state from public.automation_queue where event_id = v_ev2 and rule_id = v_rfeed) = 'dry_run');
  -- release: before its window nothing moves; at the window the row is released
  v_res := public.automation_release_deferred(now());
  perform pg_temp.chk('S5 release before the window changes nothing',
    (v_res ->> 'released')::int = 0 and (select state from public.automation_queue where id = v_q) = 'deferred');
  select fire_at into v_fire from public.automation_queue where id = v_q;
  v_res := public.automation_release_deferred(v_fire + interval '1 minute');
  perform pg_temp.chk('S5 release at the window re-queues it and audits released_deferred',
    (v_res ->> 'released')::int >= 1
    and (select state from public.automation_queue where id = v_q) = 'dry_run'
    and exists (select 1 from public.automation_audit where decision = 'released_deferred' and idempotency_key = (select idempotency_key from public.automation_queue where id = v_q)));
  -- expiry: a deferred row whose window passed is dropped, never sent
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'g' || n, '{}');
  end loop;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c2, 'g4', '{}');
  v_q := (select id from public.automation_queue where event_id = v_ev and rule_id = v_rfeed);
  perform pg_temp.chk('S5 (setup) fourth message for the second customer is deferred', (select state from public.automation_queue where id = v_q) = 'deferred');
  v_res := public.automation_release_deferred(now() + interval '10 days');
  perform pg_temp.chk('S5 release long after the expiry drops it (expired, audited, not re-queued)',
    (v_res ->> 'expired')::int >= 1
    and (select state from public.automation_queue where id = v_q) = 'expired'
    and exists (select 1 from public.automation_audit where decision = 'expired_deferred' and idempotency_key = (select idempotency_key from public.automation_queue where id = v_q)));
  -- an event whose own window ends before the next day's window is dropped at once (e.g. a 7-day AMC reminder)
  for n in 1..3 loop
    v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_ta, 'h' || n, '{}');
  end loop;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_ta, 'h4',
            jsonb_build_object('window_end', (now() + interval '2 hours')::text));
  perform pg_temp.chk('S5 a window that ends before the next release is expired immediately, audited expired_deferred',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'expired'
    and exists (select 1 from public.automation_audit where event_id = v_ev and decision = 'expired_deferred'));
  perform pg_temp.chk('S5 deferred and expired rows are not counted toward the cap or the cooldown',
    (select count(*) from public.automation_queue where org_id = v_org and customer_id = v_c_ta and message_class = 'non_job' and state = 'dry_run') = 3);
  -- cap setting is honoured
  update settings set automation_non_job_daily_cap = 1 where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_login, 'k1', '{}');
  v_ev2 := public.automation_emit(v_org, 'feedback.requested', 'ticket', gen_random_uuid(), v_c_login, 'k2', '{}');
  perform pg_temp.chk('S5 the cap is the setting (1): second non-job deferred',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_rfeed) = 'dry_run'
    and (select state from public.automation_queue where event_id = v_ev2 and rule_id = v_rfeed) = 'deferred');
  update settings set automation_non_job_daily_cap = 3 where org_id = v_org;

  -- ---------- S6: 90-day review floor ----------
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r1', '{}');
  perform pg_temp.chk('S6 first review request passes', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r2', '{}');
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_rrev;
  perform pg_temp.chk('S6 a second request for the same customer inside 90 days -> skipped_cooldown (rule cooldown was 0)', s = 'skipped_cooldown', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c_login, 'r3', '{}');
  perform pg_temp.chk('S6 another customer is unaffected', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');
  perform pg_temp.chk('S6 the floor is 2160 hours',
    (select min_cooldown_hours from public.automation_events where event_key = 'review.google_requested') = 2160);
  update public.automation_queue set created_at = now() - interval '91 days' where org_id = v_org and rule_id = v_rrev and customer_id = v_c6;
  v_ev := public.automation_emit(v_org, 'review.google_requested', 'ticket', gen_random_uuid(), v_c6, 'r4', '{}');
  perform pg_temp.chk('S6 after 91 days a new request passes again', (select state from public.automation_queue where event_id = v_ev and rule_id = v_rrev) = 'dry_run');

  -- ---------- nothing sendable ----------
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('the engine wrote nothing to whatsapp_outbox', v_ob1 = v_ob2, v_ob1::text || ' -> ' || v_ob2::text);
  perform pg_temp.chk('queue states are still only non-deliverable values',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired')));
  s := pg_temp.raises(format($q$insert into public.automation_queue (org_id, idempotency_key, rule_id, rule_key, rule_version, event_id, event_key, subject_type, subject_id, recipient_role, channel, fire_at, state)
        values (%L, 'x2', gen_random_uuid(), gen_random_uuid(), 1, gen_random_uuid(), 'a.b', 'ticket', gen_random_uuid(), 'customer', 'whatsapp', now(), 'pending')$q$, v_org));
  perform pg_temp.chk('queue CHECK still refuses a deliverable state', s like '%check constraint%', coalesce(s, 'accepted'));
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
