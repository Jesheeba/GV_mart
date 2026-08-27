-- Correction to 20260827093000 — that migration's REVOKE targeted PUBLIC,
-- which was the wrong grantee. Verified via pg_default_acl: this project
-- has Supabase's own default-privilege bootstrap configured for BOTH the
-- `postgres` and `supabase_admin` roles, each with an explicit
-- defaclobjtype='f' (functions) entry that auto-grants EXECUTE directly to
-- anon, authenticated, AND service_role on every new function the instant
-- it's created — routed straight to those roles, never through PUBLIC.
-- Confirmed by direct anon-key calls AFTER 20260827093000 was applied:
-- wa_get_amc_status/wa_identify_customer/wa_get_conversation still
-- returned real customer data. pg_proc.proacl for wa_get_amc_status showed
-- anon=X/postgres and authenticated=X/postgres as independent, explicit
-- entries — not inherited via PUBLIC membership — so REVOKE ... FROM
-- PUBLIC was a genuine no-op against the actual exposure.
--
-- Fix: revoke EXECUTE from anon and authenticated directly (service_role
-- keeps it — that's the intended caller). Also override the default-ACL
-- rule itself for both roles that own it here, so this can't reopen the
-- next time any wa_*/_wa_* function is added without its own grant line.
do $$
declare
  r record;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like 'wa\_%' or p.proname like '\_wa\_%')
  loop
    execute format('revoke execute on function public.%I(%s) from anon', r.proname, r.args);
    if r.proname <> '_wa_normalize_phone' then
      execute format('revoke execute on function public.%I(%s) from authenticated', r.proname, r.args);
    end if;
  end loop;
end;
$$;

-- The actual source of the leak — override the default ACL for the role
-- migrations actually run as (confirmed via pg_proc.proowner = postgres on
-- every existing function, including these). pg_default_acl also showed an
-- identical defaclobjtype='f' row owned by supabase_admin granting the same
-- thing — but `postgres` has no permission to alter supabase_admin's own
-- defaults (confirmed: attempting it 42501'd and rolled back this entire
-- migration on the first try). Every function in this codebase is created
-- through migration files running as postgres, never through Studio/manual
-- SQL as supabase_admin, so this covers the actual, only path new functions
-- get created through here — but it's a known, deliberately-left gap: a
-- function created some other way (e.g. directly in the Studio SQL editor,
-- if that runs as supabase_admin) would still inherit the anon/authenticated
-- default and need the same fix applied to it individually.
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
