-- Rollback for 20261121100000_admin_link_customer_google_account.sql.
-- Both functions are brand new (nothing redefined, no column/table/type changes) -- dropping
-- them is the complete undo. Safe to run even if a real master has already used the feature:
-- the audit_log rows it wrote stay (audit_log is append-only by design, never touched here),
-- and any customer already linked through it stays linked (customers.primary_profile_id /
-- profiles rows it created are ordinary data, not owned by the function) -- this only removes
-- the ADMIN TOOL, not anything it already did.
drop function if exists public.admin_link_customer_google_account(uuid, text);
drop function if exists public.admin_unlink_customer_google_account(uuid, text);
