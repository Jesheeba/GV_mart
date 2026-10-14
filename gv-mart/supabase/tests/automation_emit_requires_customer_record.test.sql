-- Rolled-back DB tests for 20261026110000_automation_emit_requires_customer_record.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves: it applies 20261026100000 and
-- 20261026110000 in ONE request and then this file, which ends in an unconditional RAISE, so nothing is committed.
-- Throwaway __TEST_ organisations only; nothing is sent; no real customer or number is touched.
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
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_sales uuid; v_tech_prof uuid; v_tech uuid;
  v_c1 uuid; v_c_other uuid;
  v_m1 text := '9400000081'; v_typed text := '9400000089'; v_mo text := '9400000085';
  v_r_cust uuid; v_r_shadow uuid; v_r_sales uuid; v_r_tech uuid;
  v_ev uuid; v_lead uuid; v_lead_t uuid; s text; n int; rec record; v_ob2 int;
begin
  perform pg_temp.chk('skipped_no_recipient is an allowed audit decision (no CHECK change needed)',
    exists (select 1 from pg_constraint c where c.conrelid = 'public.automation_audit'::regclass and c.contype = 'c'
             and pg_get_constraintdef(c.oid) like '%skipped_no_recipient%'));

  insert into organizations (name) values ('__TEST_automation_nocust') returning id into v_org;
  insert into organizations (name) values ('__TEST_automation_nocust_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tech_prof := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tech_prof, true) returning id into v_tech;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', v_m1) returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org2, '__TEST_ other org', v_mo) returning id into v_c_other;

  perform pg_temp.as_user(v_master);
  v_r_cust   := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', 'gvm_lead_welcome_en', 'en', 0, 0, null, 'live');
  v_r_shadow := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', 'gvm_lead_welcome_en', 'en', 0, 0, null, 'shadow');
  v_r_sales  := public.automation_rule_save(null, 'lead.created', 'sales', 'in_app', '{}', null, null, 0, 0, null, 'live');
  v_r_tech   := public.automation_rule_save(null, 'ticket.assigned', 'technician', 'in_app', '{}', null, null, 0, 0, null, 'live');
  perform pg_temp.as_pg();

  -- no customer id at all, and a payload number that WOULD have been used before
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', v_lead, null, 'a', jsonb_build_object('mobile', v_typed, 'sales_person_id', v_sales));
  select decision, detail ->> 'reason' as reason, recipient_masked into rec from public.automation_audit where event_id = v_ev and rule_id = v_r_cust;
  perform pg_temp.chk('live customer rule, no customer id: skipped_no_recipient / no_customer_record',
    rec.decision = 'skipped_no_recipient' and rec.reason = 'no_customer_record', coalesce(rec.decision, '-') || '/' || coalesce(rec.reason, '-'));
  perform pg_temp.chk('the audit row carries no recipient number', rec.recipient_masked is null, coalesce(rec.recipient_masked, 'null'));
  perform pg_temp.chk('no queue row exists for the refused customer rules',
    not exists (select 1 from public.automation_queue where event_id = v_ev and rule_id in (v_r_cust, v_r_shadow)));
  select decision, detail ->> 'reason' as reason into rec from public.automation_audit where event_id = v_ev and rule_id = v_r_shadow;
  perform pg_temp.chk('shadow customer rule is refused the same way (mode does not matter)',
    rec.decision = 'skipped_no_recipient' and rec.reason = 'no_customer_record', coalesce(rec.decision, '-'));
  perform pg_temp.chk('the sales rule of the same event still queues (other recipient roles untouched)',
    (select decision from public.automation_audit where event_id = v_ev and rule_id = v_r_sales) = 'dry_run');
  perform pg_temp.chk('event log: three rules considered, only the sales one queued',
    (select rules_considered from public.automation_event_log where id = v_ev) = 3
    and (select rules_queued from public.automation_event_log where id = v_ev) = 1);

  -- a customer id that does not exist, and one that belongs to another organisation
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), gen_random_uuid(), 'b', jsonb_build_object('mobile', v_typed));
  perform pg_temp.chk('an unknown customer id is treated as no customer record',
    (select detail ->> 'reason' from public.automation_audit where event_id = v_ev and rule_id = v_r_cust) = 'no_customer_record');
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c_other, 'c', jsonb_build_object('mobile', v_mo));
  perform pg_temp.chk('a customer of ANOTHER organisation is treated as no customer record',
    (select detail ->> 'reason' from public.automation_audit where event_id = v_ev and rule_id = v_r_cust) = 'no_customer_record'
    and not exists (select 1 from public.automation_queue where event_id = v_ev and rule_id = v_r_cust));

  -- a real customer: queued to the customer's own number, never the typed one
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'd', jsonb_build_object('mobile', v_typed));
  select decision, recipient_masked into rec from public.automation_audit where event_id = v_ev and rule_id = v_r_cust;
  perform pg_temp.chk('a customer with a record is queued (dry_run) to the main number, not the payload number',
    rec.decision = 'dry_run' and rec.recipient_masked = '******' || right(v_m1, 4) and rec.recipient_masked <> '******' || right(v_typed, 4),
    coalesce(rec.decision, '-') || '/' || coalesce(rec.recipient_masked, '-'));

  -- technician rule with no customer record is not a customer rule
  v_ev := public.automation_emit(v_org, 'ticket.assigned', 'ticket', gen_random_uuid(), null, 'e', jsonb_build_object('technician_id', v_tech));
  perform pg_temp.chk('a technician rule with no customer record still queues',
    (select decision from public.automation_audit where event_id = v_ev and rule_id = v_r_tech) = 'dry_run');

  -- a test subject with no customer record is refused, not blocked
  insert into leads (org_id, name, mobile, source, status, kind, is_test) values (v_org, '__TEST_ L flagged no customer', v_typed, 'field', 'new', 'service', true) returning id into v_lead_t;
  perform pg_temp.chk('a test lead with no customer record: the customer rule is skipped_no_recipient, not blocked_not_allowlisted',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_lead_t and e.event_key = 'lead.created' and a.rule_id = v_r_cust
               and a.decision = 'skipped_no_recipient' and a.detail ->> 'reason' = 'no_customer_record'));

  -- through the real trigger: a lead inserted without a customer
  insert into leads (org_id, name, mobile, source, status, kind) values (v_org, '__TEST_ L typed by staff', v_typed, 'field', 'new', 'service') returning id into v_lead;
  perform pg_temp.chk('lead insert without customer: customer rule skipped through the trigger, no queue row',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_lead and e.event_key = 'lead.created' and a.rule_id = v_r_cust and a.decision = 'skipped_no_recipient')
    and not exists (select 1 from public.automation_queue where org_id = v_org and subject_id = v_lead and rule_id = v_r_cust));

  -- privacy and unchanged guarantees
  perform pg_temp.chk('no full phone number is stored in queue or audit (including the typed number)',
    not exists (select 1 from public.automation_queue where org_id = v_org and (recipient_masked ~ '[0-9]{7,}' or detail::text like '%' || v_typed || '%'))
    and not exists (select 1 from public.automation_audit where org_id = v_org and (recipient_masked ~ '[0-9]{7,}' or detail::text like '%' || v_typed || '%')));
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('the engine wrote nothing to whatsapp_outbox', v_ob2 = 0, v_ob2::text);
  perform pg_temp.chk('queue states are still only non-deliverable values',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired')));
  perform pg_temp.chk('automation_emit is still service_role only',
    not has_function_privilege('authenticated', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
