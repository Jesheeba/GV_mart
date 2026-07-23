-- STEP 6.5 (Meeting spec D5) — "additional contact" on the technician job
-- screen. `customer_members` already models exactly this (up to 5 people per
-- customer, each with their own name/mobile, one flagged primary) but no RLS
-- policy lets a technician read it — customer_members_select_staff
-- (20260701091300_rls.sql) only covers master/operation_admin/sales_admin
-- (public.is_staff()), and technicians aren't in that list. Same gap shape
-- as the one fixed in 20260723120000_technician_customer_history_rls.sql —
-- reusing that migration's is_technician_customer() helper rather than
-- duplicating the "has this technician ever had an appointment for this
-- customer" check inline.
create policy customer_members_select_technician on customer_members
  for select using (public.is_technician_customer(customer_id));
