-- Rollback for 20261024171000_customers_org_created_index.sql.
-- Drops the (org_id, created_at desc) covering index on customers. No data
-- loss -- an index carries no information beyond what's already in the
-- table. After this rollback, the Customers list's main query (WHERE
-- org_id = $1 ORDER BY created_at DESC LIMIT 20) goes back to sorting every
-- one of the org's customer rows on every page load (the ~5.6s-per-load
-- regression this migration fixed).
drop index if exists public.customers_org_created_idx;

notify pgrst, 'reload schema';
