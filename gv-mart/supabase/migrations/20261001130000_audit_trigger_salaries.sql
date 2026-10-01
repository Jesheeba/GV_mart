-- salaries was never wired into audit_master_change (20260702090000), so
-- recomputing a payslip left no before/after trace. Same trigger pattern as
-- the other audited tables.
create trigger audit_salaries after insert or update or delete on public.salaries
  for each row execute function public.audit_master_change();
