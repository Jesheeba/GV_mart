-- Rollback for 20261016320000: removes the two seeded mapping rows and the threshold column. Nothing else depends on them
-- (wa-scheduled-tasks reads the column defensively and treats a missing value as 10).
delete from public.whatsapp_event_templates
 where (event_key, wasi_template_name) in (('po.quote_request', 'po_quote_request_doc_v3'), ('test.hello', 'hello_world'));
alter table public.settings drop constraint if exists settings_wa_skipped_alert_threshold_check;
alter table public.settings drop column if exists wa_skipped_alert_threshold;
