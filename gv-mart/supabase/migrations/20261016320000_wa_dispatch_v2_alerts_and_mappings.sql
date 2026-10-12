-- WhatsApp dispatcher v2, step 3: alert threshold and the first event -> template mappings. Additive and idempotent.
-- (20261016300000 and 20261016310000 are already applied; this is a separate file so nothing applied is edited.)
--
-- 1. settings.wa_skipped_alert_threshold: skipped_no_template rows per IST day above which the master gets an in-app alert
--    (0 = off). Default 10. The alert and the 15-minute "stuck pending" alert are raised by wa-scheduled-tasks only while
--    settings.wa_dispatch_v2_enabled is on.
-- 2. whatsapp_event_templates rows ONLY for templates that are already approved on Wasi (nothing for gvm_* yet):
--      po.quote_request  (written by _auto_draft_purchase_order and open_monthly_quote_requests)  -> po_quote_request_doc_v3
--                         supplier_name <- supplier_name; header document <- the quote PDF url
--      test.hello        (connectivity test only, never emitted by the app)                         -> hello_world (no params)
--    A row is inert until the template mirror (whatsapp_wasi_templates, filled by the template sync) shows the template as
--    approved and unduplicated. po_quote_request_doc_v3 exists twice on Wasi (en_US and en); the send code refuses a
--    duplicated name, so that mapping starts working only after the owner deletes one copy.
alter table public.settings
  add column if not exists wa_skipped_alert_threshold integer not null default 10;

alter table public.settings drop constraint if exists settings_wa_skipped_alert_threshold_check;
alter table public.settings
  add constraint settings_wa_skipped_alert_threshold_check check (wa_skipped_alert_threshold >= 0);

insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
select o.id, v.event_key, 'en', v.wasi_template_name, v.param_map
from public.organizations o
cross join (values
  ('po.quote_request', 'po_quote_request_doc_v3', '{"supplier_name": "supplier_name"}'::jsonb),
  ('test.hello', 'hello_world', '{}'::jsonb)
) as v(event_key, wasi_template_name, param_map)
on conflict (org_id, event_key, language) do nothing;
