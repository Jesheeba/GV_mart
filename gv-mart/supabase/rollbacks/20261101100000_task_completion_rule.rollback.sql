-- Rollback for 20261101100000_task_completion_rule.sql. Restores the previous behaviour exactly:
--   current_technician_id() without the is_active test, the PO trigger function from 20260925100100, and the open
--   tasks_update_assign policy from 20260921160000 (any staff or technician may update any task).
-- Re-opens the holes the migration closed. Run only on purpose.
begin;
drop trigger if exists aa_guard_task_completion on public.tasks;
drop function if exists public.guard_task_completion();

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;

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

drop policy if exists tasks_update_assign on public.tasks;
create policy tasks_update_assign on public.tasks
  for update using (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  )
  with check (
    org_id = public.current_org_id()
    and (public.is_staff() or public.current_technician_id() is not null)
  );

notify pgrst, 'reload schema';
commit;
