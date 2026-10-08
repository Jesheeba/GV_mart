-- Rollback for held/20261011100000_revoke_user_sessions.sql
drop function if exists public.revoke_user_sessions(uuid);
