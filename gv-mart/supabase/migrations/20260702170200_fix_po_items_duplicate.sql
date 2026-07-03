-- Fix: 20260702170000 created `purchase_order_items`, duplicating the
-- `po_items` table that already existed from Phase 1
-- (20260701090400_suppliers_purchase.sql, RLS in 20260701091300_rls.sql) —
-- same columns, same purpose. Drop the accidental duplicate; every function
-- in 20260702170100 that referenced it is corrected in this same pass
-- (20260702170300_automation_purchase_functions_fix.sql) to use `po_items`.
drop table if exists public.purchase_order_items;
