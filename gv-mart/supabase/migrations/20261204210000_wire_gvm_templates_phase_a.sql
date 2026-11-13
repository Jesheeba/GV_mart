-- Wires the 7 outbox events that already have a live trigger today to their
-- Meta-approved gvm_* templates (submitted + approved 2026-11-12). Pure data:
-- one whatsapp_event_templates row per (event_key, language) per org, same
-- pattern as 20261121100200_customer_link_otp_template_mapping.sql. Variable
-- names on the right of each param_map are the keys wa-event-context.ts /
-- wa-scheduled-tasks/index.ts already populate (extended in this same pass
-- to add technician_phone, product_name, amc_number, feedback_link).
--
-- Deliberately 'en' only for now — no gvm_* template has a 'ta' counterpart
-- yet, so a Tamil-preferring customer still gets free text until one exists.
do $mig$
begin
  if to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'wire_gvm_templates_phase_a: whatsapp_event_templates missing -- base schema not applied';
  end if;

  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
  select o.id, v.event_key, 'en', v.wasi_template_name, v.param_map::jsonb
  from public.organizations o
  cross join (
    values
      ('milestone.booked',    'gvm_complaint_registration',  '{"customer_name":"customer_name","complaint_number":"complaint_number"}'),
      ('milestone.assigned',  'gvm_technician_assigned',     '{"customer_name":"customer_name","complaint_number":"complaint_number","technician_name":"technician_name","technician_phone":"technician_phone"}'),
      ('milestone.on_the_way','gvm_technician_on_the_way',   '{"customer_name":"customer_name","technician_name":"technician_name","complaint_number":"complaint_number"}'),
      ('milestone.completed', 'gvm_service_completed',       '{"customer_name":"customer_name","complaint_number":"complaint_number"}'),
      ('milestone.invoice',   'gvm_purchase_confirmation',   '{"customer_name":"customer_name","product_name":"product_name"}'),
      ('amc_reminder_30',     'gvm_amc_renewal_reminder',    '{"customer_name":"customer_name","amc_number":"amc_number","expiry_date":"expiry_date"}'),
      ('amc_reminder_15',     'gvm_amc_renewal_reminder',    '{"customer_name":"customer_name","amc_number":"amc_number","expiry_date":"expiry_date"}'),
      ('amc_reminder_7',      'gvm_amc_renewal_reminder',    '{"customer_name":"customer_name","amc_number":"amc_number","expiry_date":"expiry_date"}'),
      ('feedback_request',   'gvm_customer_feedback',       '{"customer_name":"customer_name","feedback_link":"feedback_link"}')
  ) as v(event_key, wasi_template_name, param_map)
  on conflict (org_id, event_key, language) do update
    set wasi_template_name = excluded.wasi_template_name,
        param_map = excluded.param_map;

  if (select count(*) from public.whatsapp_event_templates where event_key like 'milestone.%' or event_key like 'amc_reminder_%' or event_key = 'feedback_request') < 9 then
    raise exception 'assertion failed: expected at least 9 gvm_* mapping rows (9 event_keys x >=1 org)';
  end if;
end
$mig$;
