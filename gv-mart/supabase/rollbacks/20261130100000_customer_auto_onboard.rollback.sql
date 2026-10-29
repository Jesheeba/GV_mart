-- Rollback for 20261130100000_customer_auto_onboard_schema.sql + 20261130100001_customer_auto_onboard_rpc.sql.
-- Run in this order (reverse of apply): drop the function first (it references the new columns),
-- then the columns, then restore customers.mobile's NOT NULL.
--
-- WARNING -- customers.mobile NOT NULL cannot be restored if any row created by
-- customer_auto_onboard() while this was live has a NULL mobile (any 'customer_app'-sourced
-- customer that was auto-created rather than linked, since linking always carries over the
-- existing customer's mobile). Check first:
--   select count(*) from public.customers where mobile is null;
-- If that's > 0, either backfill a value for those rows or leave mobile nullable (do not force
-- the ALTER below) -- restoring NOT NULL with existing NULL rows will fail outright, loudly, not
-- silently, so there is no risk of this half-applying.
drop function if exists public.customer_auto_onboard();

alter table public.customers drop constraint if exists customers_email_format;
alter table public.customers drop column if exists email;
alter table public.customers drop column if exists needs_review;
alter table public.customers drop column if exists needs_review_reason;

-- Only run this line after confirming (see WARNING above) that no row has mobile is null:
-- alter table public.customers alter column mobile set not null;
