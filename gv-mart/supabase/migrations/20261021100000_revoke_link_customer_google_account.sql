-- Close an account-takeover path (2026-10-14): link_customer_google_account(text).
--
-- The function links the calling auth user to the OLDEST customer with the given mobile across ALL organisations, with no proof
-- that the caller owns the number, and gives them a 'customer' profile in that customer's organisation. Despite its name it needs
-- no Google identity: any confirmed email sign-up (public sign-up is open) can call it, and then reads that customer's addresses,
-- tickets and invoices under the customer RLS.
--
-- Legitimate use today is ZERO: Google sign-in is disabled in the project, the app has no email signUp call, and the only caller
-- is the Google link card, which cannot be reached. So the grant is simply removed. service_role and the owner keep EXECUTE.
-- Replacement (OTP-gated, org-scoped, renamed) is specified in docs/security-link-customer-account.md and is NOT part of this.
--
-- Reversible with the rollback file (one GRANT restoring the exact previous ACL).

revoke execute on function public.link_customer_google_account(text) from public, anon, authenticated;
