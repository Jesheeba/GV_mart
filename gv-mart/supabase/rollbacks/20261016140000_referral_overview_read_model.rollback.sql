-- Rollback for 20261016140000_referral_overview_read_model.sql (read-only objects only; nothing else was changed).
drop function if exists public.referral_overview(uuid);
drop view if exists public.v_referral_events;
notify pgrst, 'reload schema';
