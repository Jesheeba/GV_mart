-- Rollback for held/20261011110000_audit_log_append_only.sql: restores the previous (mutable) state.
-- Previous ACL on audit_log: Supabase default grants (anon/authenticated/service_role had ALL, RLS gated clients).
drop trigger if exists audit_log_append_only on public.audit_log;
drop trigger if exists audit_log_no_truncate on public.audit_log;
drop function if exists public._trg_audit_log_append_only();
drop function if exists public.purge_test_organisation(uuid);
grant update, delete, truncate on public.audit_log to anon, authenticated, service_role;
