-- Rollback for 20261021100000_revoke_link_customer_google_account.sql.
-- Restores the exact previous ACL: {=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- WARNING: this re-opens the account-takeover path described in the migration.
grant execute on function public.link_customer_google_account(text) to public, anon, authenticated;
