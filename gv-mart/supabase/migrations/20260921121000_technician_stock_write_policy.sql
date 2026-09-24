-- Fix: 20260921110000 gave technician_stock_levels/spare_returns/
-- spare_return_items select-only RLS policies, reasoning "written only by
-- security-definer RPCs, which bypass RLS." That was wrong for
-- create_spare_handover specifically — it's `security invoker` (unlike
-- create_service_invoice, which is `security definer`), matching the
-- original 20260702200100_technicians_admin_functions.sql design: ops-staff
-- writes are authorized by RLS + an explicit is_ops_staff() belt-and-braces
-- check inside the function, not by running as a bypassing definer. Caught
-- live: an ops-staff-authenticated create_spare_handover call failed with
-- "new row violates row-level security policy for table
-- technician_stock_levels" the moment it tried to upsert the van-side row.
-- The upcoming create_spare_return RPC (Group 3) is invoker too, for the
-- same reason, so it needs this same write policy.
create policy technician_stock_levels_write_ops on technician_stock_levels for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy spare_returns_write_ops on spare_returns for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy spare_return_items_write_ops on spare_return_items for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
