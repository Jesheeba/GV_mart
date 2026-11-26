-- Rollback for 20261216120000_primary_member_sync.sql. Removes the sync and the stale-address-parts triggers. The
-- one-off blank fills (member email from the account email, blank professions) are not undone: they only filled
-- empty values, and the pre-apply backup has the before-state if ever needed.
drop trigger if exists zz_sync_primary_member_to_customer on public.customer_members;
drop trigger if exists zz_sync_customer_to_primary_member on public.customers;
drop trigger if exists clear_stale_address_parts on public.addresses;
drop function if exists public._sync_primary_member_to_customer();
drop function if exists public._sync_customer_to_primary_member();
drop function if exists public._clear_stale_address_parts();
notify pgrst, 'reload schema';
