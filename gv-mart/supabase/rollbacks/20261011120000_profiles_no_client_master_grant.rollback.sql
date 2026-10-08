-- Rollback for held/20261011120000_profiles_no_client_master_grant.sql
drop trigger if exists guard_profile_no_client_master on public.profiles;
drop function if exists public.guard_profile_no_client_master();
