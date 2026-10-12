-- Rollback for 20261016300000_wa_dispatch_v2_schema.sql.
--
-- RECOMMENDED rollback is NOT this file: switch the flag off (update settings set wa_dispatch_v2_enabled = false) and
-- leave the additive schema in place; nothing reads it while the flag is off.
-- Run this only to remove the schema entirely. It discards delivery history (delivered_at/read_at/delivery_status),
-- the contacts/last-inbound table, the mirrored Wasi template list and the event->template mapping.
--
-- Order: 20261016310000's rollback first (the trigger reads settings.wa_dispatch_v2_enabled).
begin;

-- 1. rows the old CHECK would reject
update public.whatsapp_outbox
   set status = 'failed',
       error = coalesce(error, '') || case when error is null then '' else ' | ' end || 'rolled back from dispatcher v2 (was ' || status || ')'
 where status in ('pending', 'skipped_no_template');

-- 2. objects
drop table if exists public.whatsapp_event_templates;
drop table if exists public.whatsapp_wasi_templates;
drop function if exists public.wa_touch_contact(uuid, text, timestamptz);
drop table if exists public.whatsapp_contacts;

-- 3. columns and constraints
drop index if exists public.whatsapp_outbox_pending_idx;
alter table public.whatsapp_outbox drop constraint if exists whatsapp_outbox_delivery_status_check;
alter table public.whatsapp_outbox
  drop column if exists wasi_message_id,
  drop column if exists delivery_status,
  drop column if exists delivered_at,
  drop column if exists read_at,
  drop column if exists failed_at,
  drop column if exists claimed_at,
  drop column if exists wasi_response,
  drop column if exists template_name,
  drop column if exists template_params;

alter table public.whatsapp_outbox drop constraint if exists whatsapp_outbox_status_check;
alter table public.whatsapp_outbox
  add constraint whatsapp_outbox_status_check check (status in ('sent', 'failed', 'received'));

alter table public.settings drop column if exists wa_dispatch_v2_enabled;

-- The 'superseded by retry' markers written by the migration are history and are left as they are.
commit;
