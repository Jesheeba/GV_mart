-- Rollback for 20261101100000_task_status_guard.sql
drop trigger if exists aa_guard_task_status_change on public.tasks;
drop function if exists public.guard_task_status_change();

-- original definition (20260925100100_po_paid_functions.sql): no auth.uid()/is_master() gate
create or replace function public._po_task_completed_marks_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ref_type = 'purchase_order' and new.status = 'done' and (old.status is distinct from 'done') then
    update public.purchase_orders
      set status = 'paid'
      where id = new.ref_id and org_id = new.org_id and status in ('sent', 'received');
  end if;
  return new;
end;
$$;
