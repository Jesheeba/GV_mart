-- Rolled-back test for 20261029130000_automation_handoff_amc_ref_type.sql (dispatcher side of the AMC hand-off).
-- Runner: BEGIN; 20261029100000 (hand-off) ; 20261029130000 ; this block (ends in RAISE). Throwaway organisation only.
create temp table res (n serial, line text);
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;

do $t$
declare
  v_org uuid; v_c uuid; v_r uuid; v_rk uuid; v_brand uuid; v_model uuid; v_prod uuid; v_plan uuid; v_con uuid;
  v_ev uuid; v_res jsonb; v_o record; v_n int;
begin
  perform pg_temp.chk('whitelist now holds amc_contract exactly once, alongside the three existing types',
    (select array_agg(ref_type order by ref_type) from public.automation_handoff_ref_types)
      = array['amc_contract', 'invoice', 'service_ticket', 'service_visit']);

  insert into organizations (name) values ('__TEST_amc_ref') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ amc', '9400000091') returning id into v_c;
  insert into brands (org_id, name, category) values (v_org, '__TEST_ brand', 'ro') returning id into v_brand;
  insert into models (org_id, brand_id, name) values (v_org, v_brand, '__TEST_ model') returning id into v_model;
  insert into products (org_id, name, category, brand_id, model_id, price) values (v_org, '__TEST_ RO', 'ro', v_brand, v_model, 10000) returning id into v_prod;
  insert into amc_plans (org_id, name, years, price, visits_per_year) values (v_org, '__TEST_ Silver', 1, 3000, 1) returning id into v_plan;
  insert into amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status)
  values (v_org, v_c, v_prod, v_plan, current_date - 300, current_date + 30, 'active') returning id into v_con;

  update settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = array['9400000091'] where org_id = v_org;
  insert into whatsapp_wasi_templates (org_id, wasi_name, language, category, status) values (v_org, 'gvm_amc_expiring_en', 'en', 'utility', 'approved');
  insert into whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
  values (v_org, 'gvm_amc_expiring', 'en', 'gvm_amc_expiring_en', '{"customer_name":"name","product_name":"product","expiry_date":"expiry_date","days_left":"days_left"}');

  -- a live rule, written directly as the owner (the master RPC needs a session; this test is about the hand-off only)
  insert into public.automation_rules (org_id, event_key, recipient_role, channel, status, template_name, language)
  values (v_org, 'amc.expiring', 'customer', 'whatsapp', 'live', 'gvm_amc_expiring_en', 'en') returning id, rule_key into v_r, v_rk;

  v_ev := public.automation_emit(v_org, 'amc.expiring', 'amc_contract', v_con, v_c, 'expiring@30',
            jsonb_build_object('days_left', 30, 'expiry_date', (current_date + 30)::text, 'product_id', v_prod));
  perform pg_temp.chk('the emitted AMC row waits as a live dry_run row',
    (select state from public.automation_queue where event_id = v_ev and rule_id = v_r) = 'dry_run');

  v_res := public.automation_handoff_due(now() + interval '1 minute');
  select * into v_o from public.whatsapp_outbox where org_id = v_org and template = 'gvm_amc_expiring';
  perform pg_temp.chk('the AMC row is handed over as a pending template row with ref_type amc_contract and the contract id',
    (v_res ->> 'handed_over')::int = 1 and v_o.status = 'pending' and v_o.ref_type = 'amc_contract' and v_o.ref_id = v_con
    and v_o.to_mobile = '9400000091' and v_o.type = 'template');
  perform pg_temp.chk('the payload carries days_left and expiry_date (the dispatcher turns them into variables), no number, no name',
    (v_o.payload ->> 'days_left')::int = 30 and v_o.payload ? 'expiry_date' and v_o.payload::text !~ '9400000091' and v_o.payload::text !~ '__TEST_');
  perform pg_temp.chk('legacy writers did not touch it (still pending, no wamid)', v_o.wa_message_id is null and v_o.status = 'pending');

  -- the "no live rule means no row" rule is the same code path for every subject and is covered by automation_phase3b.test.sql;
  -- here: a second emit for the same contract and window is a duplicate and adds nothing
  v_n := (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_amc_expiring');
  perform public.automation_emit(v_org, 'amc.expiring', 'amc_contract', v_con, v_c, 'expiring@30', jsonb_build_object('days_left', 30));
  v_res := public.automation_handoff_due(now() + interval '1 minute');
  perform pg_temp.chk('a repeated window adds no outbox row',
    (select count(*) from public.whatsapp_outbox where org_id = v_org and template = 'gvm_amc_expiring') = v_n and (v_res ->> 'handed_over')::int = 0);
  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
