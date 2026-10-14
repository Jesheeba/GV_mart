-- Rolled-back DB tests for 20261026100000_automation_item_added_and_per_item_cooldown.
-- NOT RUN (written for review). Run only through the rehearsal wrapper the owner approves: the wrapper applies the migration
-- inside ONE transaction, then runs this file, which ends in an unconditional RAISE so nothing is ever committed. Throwaway
-- __TEST_ organisation only; no real customer, number or message is touched; nothing is sent (the engine has no sender).
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
  v_org uuid; v_master uuid; v_sales uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid;
  v_m1 text := '9400000071'; v_m2 text := '9400000072'; v_m3 text := '9400000073'; v_m4 text := '9400000074';
  v_brand uuid; v_model uuid; v_pa uuid; v_pb uuid; v_sp uuid;
  v_ka text; v_kb text; v_kc text;
  v_r_item uuid; v_r_added uuid; v_r_wide uuid; v_r_old uuid;
  v_ev uuid; v_ev2 uuid; s text; n int; rec record;
  v_lead uuid; v_old_lead uuid; v_new_lead uuid; v_li uuid;
  v_ob1 int; v_ob2 int;
begin
  -- ---------- schema / catalogue / grants ----------
  perform pg_temp.chk('automation_queue.item_key exists, nullable text',
    (select data_type || '/' || is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'automation_queue' and column_name = 'item_key') = 'text/YES');
  perform pg_temp.chk('automation_rules.cooldown_per_item exists, boolean not null default false',
    (select data_type || '/' || is_nullable || '/' || column_default from information_schema.columns
      where table_schema = 'public' and table_name = 'automation_rules' and column_name = 'cooldown_per_item') = 'boolean/NO/false');
  perform pg_temp.chk('catalogue: enquiry.item_added has an emitter, lead subject, customer + sales recipients',
    exists (select 1 from public.automation_events where event_key = 'enquiry.item_added' and has_emitter and not is_scheduled
              and subject_type = 'lead' and supported_recipients = '{customer,sales}'));
  perform pg_temp.chk('automation_rule_save: the 16-argument version is gone, the 17-argument one exists',
    to_regprocedure('public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer)') is null
    and to_regprocedure('public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)') is not null);
  perform pg_temp.chk('automation_rule_save grants: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and has_function_privilege('service_role', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.automation_rule_save(uuid,text,text,text,jsonb,text,text,integer,integer,integer,text,uuid,text,text,boolean,integer,boolean)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.proname = 'automation_rule_save' and p.pronamespace = 'public'::regnamespace and a.grantee = 0));
  perform pg_temp.chk('automation_emit still service_role only; the new trigger function is not callable by clients',
    not has_function_privilege('authenticated', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.automation_emit(uuid,text,text,uuid,uuid,text,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public._trg_automation_emit_lead_item()', 'execute')
    and not has_function_privilege('anon', 'public._trg_automation_emit_lead_item()', 'execute'));
  perform pg_temp.chk('the lead_items trigger exists and is an AFTER INSERT row trigger',
    exists (select 1 from pg_trigger t where t.tgrelid = 'public.lead_items'::regclass and t.tgname = 'zz_automation_emit_lead_item'
             and not t.tgisinternal and (t.tgtype & 1) = 1 and (t.tgtype & 4) = 4 and (t.tgtype & 2) = 0));

  -- ---------- fixtures ----------
  insert into organizations (name) values ('__TEST_automation_item') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c1', v_m1) returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c2', v_m2) returning id into v_c2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c3', v_m3) returning id into v_c3;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c4', v_m4) returning id into v_c4;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO A', 'ro', v_brand, v_model, 10000) returning id into v_pa;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO B', 'ro', v_brand, v_model, 12000) returning id into v_pb;
  insert into spares (org_id, name, price) values (v_org, '__TEST_ spare', 100) returning id into v_sp;
  v_ka := v_pa::text; v_kb := v_pb::text; v_kc := v_sp::text;

  -- ---------- rule save: the new knob ----------
  perform pg_temp.as_user(v_master);
  v_r_item  := public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{"has_item": true}', 'gvm_enquiry_video_en', 'en', 0, 720, null, 'live', null, null, null, null, 72, true);
  v_r_added := public.automation_rule_save(null, 'enquiry.item_added', 'customer', 'whatsapp', '{"has_item": true}', 'gvm_enquiry_video_ta', 'ta', 0, 720, null, 'live', null, null, null, null, 72, true);
  v_r_wide  := public.automation_rule_save(null, 'lead.stage.won', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 720, null, 'live');
  perform pg_temp.as_pg();
  perform pg_temp.chk('rule save stores cooldown_per_item; omitted it is false',
    (select cooldown_per_item from public.automation_rules where id = v_r_item)
    and (select cooldown_per_item from public.automation_rules where id = v_r_added)
    and not (select cooldown_per_item from public.automation_rules where id = v_r_wide));
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises($q$select public.automation_rule_save(null, 'lead.created', 'customer', 'whatsapp', '{}', null, null, 0, 0, null, 'live', null, null, null, null, 72, true)$q$);
  perform pg_temp.as_pg();
  perform pg_temp.chk('a non-master still cannot save a rule', s like '%only the master%', coalesce(s, 'accepted'));
  -- a new version keeps the knob only if it is passed again (immutable versions): v2 without the flag is false
  perform pg_temp.as_user(v_master);
  v_r_old := public.automation_rule_save((select rule_key from public.automation_rules where id = v_r_wide), 'lead.stage.won', 'customer', 'whatsapp', '{}', 'gvm_thanks_en', 'en', 0, 720, null, 'live', null, 'v2');
  perform pg_temp.as_pg();
  perform pg_temp.chk('a saved version 2 has its own cooldown_per_item (false when not passed)',
    not (select cooldown_per_item from public.automation_rules where id = v_r_old) and (select version from public.automation_rules where id = v_r_old) = 2);

  -- ---------- per-item cooldown ----------
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('first enquiry for item A is queued (dry_run)', s = 'dry_run', coalesce(s, '-'));
  perform pg_temp.chk('the queue row stores item_key A and the audit detail carries it',
    (select item_key from public.automation_queue where event_id = v_ev and rule_id = v_r_item) = v_ka
    and (select detail ->> 'item_key' from public.automation_audit where event_id = v_ev and rule_id = v_r_item) = v_ka);

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('same customer, same item, another lead inside 720 h: skipped_cooldown', s = 'skipped_cooldown', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('same customer, a DIFFERENT item B: queued (the cooldown is per item)', s = 'dry_run', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c2, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('a DIFFERENT customer, same item A: queued (the cooldown is per customer)', s = 'dry_run', coalesce(s, '-'));

  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c1, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_item;
  perform pg_temp.chk('no item_key on the event: falls back to the whole-customer cooldown (never weaker)', s = 'skipped_cooldown', coalesce(s, '-'));

  -- the other rule sends the same template base (_ta vs _en): the window is shared across the two events
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', gen_random_uuid(), v_c1, 'item:x1',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_added;
  perform pg_temp.chk('Item added for item A after Enquiry created for item A: skipped_cooldown (shared template window)', s = 'skipped_cooldown', coalesce(s, '-'));
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', gen_random_uuid(), v_c1, 'item:x2',
            jsonb_build_object('kind', 'spare', 'has_item', true, 'item_key', v_kc));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_added;
  perform pg_temp.chk('Item added for a new item C: queued', s = 'dry_run', coalesce(s, '-'));

  -- a rule WITHOUT cooldown_per_item keeps the old whole-customer behaviour whatever the item is
  v_ev := public.automation_emit(v_org, 'lead.stage.won', 'lead', gen_random_uuid(), v_c2, 'won',
            jsonb_build_object('item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev and rule_id = v_r_old;
  perform pg_temp.chk('rule without cooldown_per_item: first send is queued', s = 'dry_run', coalesce(s, '-'));
  v_ev2 := public.automation_emit(v_org, 'lead.stage.won', 'lead', gen_random_uuid(), v_c2, 'won',
            jsonb_build_object('item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_old;
  perform pg_temp.chk('a rule without cooldown_per_item: a second item inside the window is still skipped_cooldown (unchanged)', s = 'skipped_cooldown', coalesce(s, '-'));

  -- replay protection: the same occurrence for the same lead is a duplicate, not a second send
  v_lead := gen_random_uuid();
  v_ev := public.automation_emit(v_org, 'enquiry.item_added', 'lead', v_lead, v_c3, 'item:replay',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  v_ev2 := public.automation_emit(v_org, 'enquiry.item_added', 'lead', v_lead, v_c3, 'item:replay',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_ka));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_added;
  perform pg_temp.chk('replaying the same item occurrence is skipped_duplicate', s = 'skipped_duplicate', coalesce(s, '-'));

  -- ---------- item_key is stored at the blocked and deferred insert sites too ----------
  update settings set wa_test_mode_enabled = true, wa_test_allowed_numbers = '{}'::text[] where org_id = v_org;
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c4, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  perform pg_temp.chk('blocked site: state blocked_not_allowlisted and item_key stored',
    (select state || '/' || coalesce(item_key, '-') from public.automation_queue where event_id = v_ev and rule_id = v_r_item)
      = 'blocked_not_allowlisted/' || v_kb);
  v_ev2 := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c4, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  select decision into s from public.automation_audit where event_id = v_ev2 and rule_id = v_r_item;
  perform pg_temp.chk('a blocked row does not count toward the cooldown (same item, next attempt is not skipped_cooldown)',
    s = 'blocked_not_allowlisted', coalesce(s, '-'));
  update settings set wa_test_mode_enabled = false, wa_test_allowed_numbers = '{}'::text[], automation_non_job_daily_cap = 1 where org_id = v_org;
  -- c3 has one non-job row today (the replay probe); cap 1 -> the next different item is deferred
  v_ev := public.automation_emit(v_org, 'lead.created', 'lead', gen_random_uuid(), v_c3, 'created',
            jsonb_build_object('kind', 'product', 'has_item', true, 'item_key', v_kb));
  perform pg_temp.chk('deferred site: state deferred and item_key stored',
    (select state || '/' || coalesce(item_key, '-') from public.automation_queue where event_id = v_ev and rule_id = v_r_item)
      = 'deferred/' || v_kb,
    coalesce((select state from public.automation_queue where event_id = v_ev and rule_id = v_r_item), 'no row'));
  update settings set automation_non_job_daily_cap = 3 where org_id = v_org;

  -- ---------- lead payload fields ----------
  v_lead := null;
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, product_id, qty)
    values (v_org, v_c1, '__TEST_ L with item', v_m1, 'customer_app', 'new', 'product', v_pa, 1) returning id into v_lead;
  perform pg_temp.chk('lead.created payload carries product_id, spare_id, has_item and item_key',
    (select payload_keys from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'lead.created')
      @> array['product_id', 'spare_id', 'has_item', 'item_key']);
  perform pg_temp.chk('the rule with condition has_item = true matched the new lead (queued or skipped_cooldown, not skipped_condition)',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_lead and e.event_key = 'lead.created' and a.rule_id = v_r_item
               and a.decision in ('dry_run', 'skipped_cooldown')));
  insert into leads (org_id, customer_id, name, mobile, source, status, kind)
    values (v_org, v_c2, '__TEST_ L no item', v_m2, 'walk_in', 'new', 'service') returning id into v_new_lead;
  perform pg_temp.chk('a lead with no item does not satisfy has_item = true (skipped_condition)',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_new_lead and e.event_key = 'lead.created' and a.rule_id = v_r_item and a.decision = 'skipped_condition'));

  -- ---------- the enquiry.item_added trigger ----------
  -- a lead created in THIS transaction: its items are lead.created material, not item_added
  insert into lead_items (org_id, lead_id, product_id, qty) values (v_org, v_lead, v_pa, 1);
  perform pg_temp.chk('an item added to a lead created in the same transaction emits no enquiry.item_added',
    not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'));

  -- an older open lead: items inserted by the system (merged enquiry) emit once, for the first item only
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c4, '__TEST_ L old open', v_m4, 'customer_app', 'new', 'product', now() - interval '2 days') returning id into v_old_lead;
  insert into lead_items (org_id, lead_id, product_id, qty) values (v_org, v_old_lead, v_pa, 1), (v_org, v_old_lead, v_pb, 1);
  select count(*) into n from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added';
  perform pg_temp.chk('two items added to an older lead in one submission: exactly ONE enquiry.item_added (first item only)', n = 1, n::text);
  perform pg_temp.chk('the event is for the customer of the lead and carries the first item as item_key',
    (select customer_id from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added') = v_c4
    and exists (select 1 from public.automation_queue q where q.org_id = v_org and q.subject_id = v_old_lead and q.event_key = 'enquiry.item_added'
                  and q.item_key = v_pa::text));
  perform pg_temp.chk('the item_added audit row is recorded for the item_added rule',
    exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
             where e.subject_id = v_old_lead and e.event_key = 'enquiry.item_added' and a.rule_id = v_r_added));
  perform pg_temp.chk('payload keys of the item_added event include item_key, has_item, product_id, spare_id, kind',
    (select payload_keys from public.automation_event_log where org_id = v_org and subject_id = v_old_lead and event_key = 'enquiry.item_added')
      @> array['item_key', 'has_item', 'product_id', 'spare_id', 'kind', 'sales_person_id', 'mobile']);

  -- a spare-only item: kind is derived as spare
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c2, '__TEST_ L old spare', v_m2, 'customer_app', 'new', 'spare', now() - interval '3 days') returning id into v_lead;
  insert into lead_items (org_id, lead_id, spare_id, qty) values (v_org, v_lead, v_sp, 2);
  perform pg_temp.chk('a spare item on an older lead emits item_added with item_key = the spare id',
    exists (select 1 from public.automation_queue q where q.org_id = v_org and q.subject_id = v_lead and q.event_key = 'enquiry.item_added'
                and q.item_key = v_sp::text)
    or exists (select 1 from public.automation_audit a join public.automation_event_log e on e.id = a.event_id
                where e.subject_id = v_lead and e.event_key = 'enquiry.item_added' and a.detail ->> 'item_key' = v_sp::text));

  -- a staff member adding an item through the app is not a customer enquiry
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old staff', v_m3, 'customer_app', 'new', 'product', now() - interval '4 days') returning id into v_lead;
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$insert into public.lead_items (org_id, lead_id, product_id, qty) values (%L, %L, %L, 1)$q$, v_org, v_lead, v_pa));
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff insert of an item is allowed by RLS and emits no enquiry.item_added',
    s is null and not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'),
    coalesce(s, 'ok'));

  -- an item row with neither a product nor a spare emits nothing
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old empty', v_m3, 'customer_app', 'new', 'product', now() - interval '5 days') returning id into v_lead;
  insert into lead_items (org_id, lead_id, qty) values (v_org, v_lead, 1);
  perform pg_temp.chk('an item with no product and no spare emits nothing',
    not exists (select 1 from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added'));

  -- the trigger swallows its own failure: a lead_items insert must still succeed
  insert into leads (org_id, customer_id, name, mobile, source, status, kind, created_at)
    values (v_org, v_c3, '__TEST_ L old fail', v_m3, 'customer_app', 'new', 'product', now() - interval '6 days') returning id into v_lead;
  update settings set automation_enabled = false where org_id = v_org;
  s := pg_temp.raises(format($q$insert into public.lead_items (org_id, lead_id, product_id, qty) values (%L, %L, %L, 1)$q$, v_org, v_lead, v_pb));
  perform pg_temp.chk('with automation switched off the insert still succeeds and the event is logged as global_off',
    s is null and (select outcome from public.automation_event_log where org_id = v_org and subject_id = v_lead and event_key = 'enquiry.item_added') = 'global_off',
    coalesce(s, 'ok'));
  update settings set automation_enabled = true where org_id = v_org;

  -- ---------- unchanged guarantees ----------
  perform pg_temp.chk('queue states are still only non-deliverable values',
    not exists (select 1 from public.automation_queue where org_id = v_org and state not in ('dry_run', 'blocked_not_allowlisted', 'deferred', 'expired')));
  select count(*) into v_ob2 from public.whatsapp_outbox where org_id = v_org;
  perform pg_temp.chk('the engine wrote nothing to whatsapp_outbox', v_ob2 = 0, v_ob2::text);
  perform pg_temp.chk('wa_dispatch_v2_enabled untouched',
    not coalesce((select wa_dispatch_v2_enabled from settings where org_id = v_org), false));
  perform pg_temp.chk('no full phone number is stored in queue or audit',
    not exists (select 1 from public.automation_queue where org_id = v_org and recipient_masked ~ '[0-9]{7,}')
    and not exists (select 1 from public.automation_audit where org_id = v_org and recipient_masked ~ '[0-9]{7,}'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
