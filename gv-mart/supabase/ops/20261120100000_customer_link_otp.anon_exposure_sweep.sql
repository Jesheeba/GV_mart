-- Anon/PUBLIC exposure sweep for the customer-link-otp feature, to run AFTER the real apply
-- (not part of this phase's rehearsal — the apply script's own step 9x already runs an
-- equivalent diff-based check automatically at apply time and refuses the apply if it finds a
-- newly-leaked function; this is the same check made runnable on its own afterwards, e.g. days
-- later as a standing health check, without needing to re-run the whole apply script).
--
-- Read-only. Safe to run at any time, including against the live project, with no rehearsal
-- wrapper needed (nothing here writes anything).
select
  -- 1. The 3 new tables must grant nothing to anon or to a bare authenticated role (every access
  -- must go through the SECURITY DEFINER RPCs, never a direct table read).
  (not has_table_privilege('anon', 'public.customer_link_otp_challenges', 'SELECT')) as challenges_anon_denied,
  (not has_table_privilege('anon', 'public.customer_link_otp_send_log', 'SELECT')) as send_log_anon_denied,
  (not has_table_privilege('anon', 'public.customer_link_otp_settings', 'SELECT')) as settings_anon_denied,
  (not has_table_privilege('authenticated', 'public.customer_link_otp_challenges', 'SELECT')) as challenges_authenticated_denied,
  (not has_table_privilege('authenticated', 'public.customer_link_otp_send_log', 'SELECT')) as send_log_authenticated_denied,
  (not has_table_privilege('authenticated', 'public.customer_link_otp_settings', 'SELECT')) as settings_authenticated_denied,
  -- 2. The 2 public RPCs must be executable by authenticated, never by anon/PUBLIC.
  (has_function_privilege('authenticated', 'public.request_customer_link_code(text)', 'EXECUTE')) as request_rpc_authenticated_ok,
  (not has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')) as request_rpc_anon_denied,
  (has_function_privilege('authenticated', 'public.verify_customer_link_code(text)', 'EXECUTE')) as verify_rpc_authenticated_ok,
  (not has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')) as verify_rpc_anon_denied,
  -- 3. The flag-read helper is intentionally readable by authenticated (a boolean, not PII) but
  -- still must never be anon-executable (an unauthenticated prober should not even learn whether
  -- the feature exists).
  (has_function_privilege('authenticated', 'public.is_customer_link_otp_enabled()', 'EXECUTE')) as flag_helper_authenticated_ok,
  (not has_function_privilege('anon', 'public.is_customer_link_otp_enabled()', 'EXECUTE')) as flag_helper_anon_denied,
  -- 4. Every SECURITY DEFINER function this migration creates must pin search_path explicitly
  -- (never rely on the ambient default, which this phase's own rehearsal found is NOT just
  -- `public` on this project -- see the migration's own pgcrypto note).
  (
    select bool_and(p.proconfig is not null and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('is_customer_link_otp_enabled', 'request_customer_link_code', 'verify_customer_link_code')
      and p.prosecdef -- security definer only
  ) as all_definer_functions_pin_search_path,
  -- 5. the permanently-revoked old function must STILL be revoked -- this feature's migration
  -- must never accidentally re-grant it.
  (not has_function_privilege('authenticated', 'public.link_customer_google_account(text)', 'EXECUTE')) as old_vulnerable_function_still_revoked,
  (not has_function_privilege('anon', 'public.link_customer_google_account(text)', 'EXECUTE')) as old_vulnerable_function_still_revoked_anon;
