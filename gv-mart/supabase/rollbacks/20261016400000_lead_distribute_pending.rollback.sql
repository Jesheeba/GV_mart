-- Rollback for held/20261016400000_lead_distribute_pending.sql: waiting leads (auto_assign_pending) are simply no longer
-- distributed automatically; they stay unassigned and are assigned by hand as before. Leads already distributed stay assigned.
drop trigger if exists settings_distribute_pending on public.settings;
drop trigger if exists profiles_distribute_pending on public.profiles;
drop function if exists public._trg_settings_distribute_pending();
drop function if exists public._trg_profile_distribute_pending();
drop function if exists public._lead_distribute_pending(uuid);
