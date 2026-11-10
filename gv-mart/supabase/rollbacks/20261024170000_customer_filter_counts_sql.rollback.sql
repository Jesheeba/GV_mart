-- Rollback for 20261024170000_customer_filter_counts_sql.sql.
-- Drops the customer_filter_counts() RPC and the two covering indexes it
-- added on invoices/service_tickets. Nothing to export first -- this
-- migration created no tables and stored no data of its own; the function
-- only ever read existing rows.
-- After this rollback, src/services/customers.ts#getCustomerFilterCounts
-- (if still wired to call customer_filter_counts()) will start failing --
-- revert that call site to the pre-20261024170000 client-side version
-- before or alongside running this.
drop function if exists public.customer_filter_counts();
drop index if exists public.invoices_org_customer_created_idx;
drop index if exists public.service_tickets_org_customer_created_idx;

notify pgrst, 'reload schema';
