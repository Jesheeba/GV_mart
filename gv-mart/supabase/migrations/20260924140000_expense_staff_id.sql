-- Salary tracking (item 1 of the 2026-09-24 Accounts/Expenses change
-- request). Both the existing technician payroll calculation
-- (compute_salary -> salaries table, UNCHANGED) and a new manual entry path
-- for non-technician staff (master/operation_admin/sales_admin) write into
-- this SAME expenses table under category='salary', distinguished by
-- staff_id — giving one combined salary-spend figure with per-person
-- drill-down. staff_id references profiles directly (not technicians),
-- since it must identify ANY staff role, not just technicians.
alter table public.expenses add column if not exists staff_id uuid references public.profiles (id) on delete set null;

create index if not exists expenses_staff_id_idx on public.expenses (staff_id) where staff_id is not null;
