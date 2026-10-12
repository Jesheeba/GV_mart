-- Rolled-back test for migrations/20261016320000_wa_dispatch_v2_alerts_and_mappings.sql.
-- Runner: BEGIN; that migration; this block (ends in RAISE). 20261016300000/310000 must already be applied.
do $t$
declare
  res text := ''; v_org uuid; n int;
begin
  insert into organizations(name) values ('__TEST_wa_alerts') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;

  select wa_skipped_alert_threshold into n from settings where org_id = v_org;
  res := res || E'\n' || case when n = 10 then 'ok   alert threshold defaults to 10 per day' else 'FAIL default ' || coalesce(n::text, 'null') end;
  begin
    update settings set wa_skipped_alert_threshold = -1 where org_id = v_org;
    res := res || E'\nFAIL a negative threshold was accepted';
  exception when check_violation then res := res || E'\nok   a negative threshold is refused';
  end;
  update settings set wa_skipped_alert_threshold = 0 where org_id = v_org;
  res := res || E'\nok   0 (alert off) is accepted';

  select count(*) into n from whatsapp_event_templates where wasi_template_name like 'gvm\_%' escape '\';
  res := res || E'\n' || case when n = 0 then 'ok   no mapping row exists for any gvm_* template' else 'FAIL gvm mapping rows: ' || n end;
  select count(*) into n from (select distinct event_key, wasi_template_name from whatsapp_event_templates) s
   where (event_key, wasi_template_name) not in (('po.quote_request', 'po_quote_request_doc_v3'), ('test.hello', 'hello_world'));
  res := res || E'\n' || case when n = 0 then 'ok   only the two seeded mappings exist' else 'FAIL unexpected mapping rows: ' || n end;
  select count(*) into n from whatsapp_event_templates
   where event_key = 'po.quote_request' and language = 'en' and wasi_template_name = 'po_quote_request_doc_v3' and param_map = '{"supplier_name": "supplier_name"}'::jsonb;
  res := res || E'\n' || case when n >= 1 then 'ok   po.quote_request -> po_quote_request_doc_v3 with Wasi''s own param name' else 'FAIL quote request mapping missing' end;

  -- idempotent: applying the insert again adds nothing
  select count(*) into n from whatsapp_event_templates;
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
  select o.id, 'po.quote_request', 'en', 'po_quote_request_doc_v3', '{"supplier_name": "supplier_name"}'::jsonb from organizations o
  on conflict (org_id, event_key, language) do nothing;
  res := res || E'\n' || case when (select count(*) from whatsapp_event_templates) = n + 1 then 'ok   re-running the seed adds only the new throwaway organisation row' else 'FAIL not idempotent' end;

  raise exception E'RESULTS:%', res;
end
$t$;
