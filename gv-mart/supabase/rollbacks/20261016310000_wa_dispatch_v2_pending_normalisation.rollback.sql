-- Rollback for 20261016310000_wa_dispatch_v2_pending_normalisation.sql.
-- Switching settings.wa_dispatch_v2_enabled OFF already makes the trigger inert; this removes it entirely.
-- Rows already written as 'pending' are unaffected (the legacy dispatcher ignores status and picks rows by
-- wa_message_id is null and retried_at is null, exactly as before).
drop trigger if exists wa_outbox_pending_normalise on public.whatsapp_outbox;
drop function if exists public._trg_wa_outbox_pending_normalise();
