-- Follow-up to 20261006130000 (profiles escalation fix): the remaining
-- "own row" policies that let the row's owner write ANY column.
--
-- As before, the column guards are SECURITY INVOKER triggers keyed on
-- current_user, so SECURITY DEFINER RPCs and the service role are untouched;
-- they also skip nested trigger writes (pg_trigger_depth() > 1). The guards
-- are named aa_* so they fire before any other BEFORE trigger on the table.

-- ── 1. Customers can't insert tickets/leads directly ──────────────────────
-- Nothing in the app does a direct customer insert: tickets come from
-- book_service_ticket / the WhatsApp wrappers and leads from
-- request_callback / the enquiry RPCs, all SECURITY DEFINER. A direct insert
-- let a customer pick any status/priority/assignment fields and skip the
-- booking rules entirely.
drop policy if exists service_tickets_insert_own_customer on public.service_tickets;
drop policy if exists leads_insert_own_customer on public.leads;

-- ── 2. tasks: an assignee may only move status / roll the due date ────────
create or replace function public.guard_task_assignee_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') or pg_trigger_depth() > 1 then
    return new;
  end if;
  if old.assignee_id = auth.uid() and not public.is_ops_staff() then
    if (to_jsonb(new) - array['status', 'due_date', 'original_due_date', 'rolled_count', 'updated_at'])
       is distinct from (to_jsonb(old) - array['status', 'due_date', 'original_due_date', 'rolled_count', 'updated_at']) then
      raise exception 'tasks: you can only update the status of a task assigned to you';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_guard_task_assignee_update on public.tasks;
create trigger aa_guard_task_assignee_update
  before update on public.tasks
  for each row execute function public.guard_task_assignee_update();

-- ── 3. notifications: the recipient may only mark read/unread ─────────────
create or replace function public.guard_notification_recipient_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') or pg_trigger_depth() > 1 then
    return new;
  end if;
  if old.user_id = auth.uid() then
    if (to_jsonb(new) - array['is_read', 'updated_at'])
       is distinct from (to_jsonb(old) - array['is_read', 'updated_at']) then
      raise exception 'notifications: you can only mark a notification read or unread';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_guard_notification_recipient_update on public.notifications;
create trigger aa_guard_notification_recipient_update
  before update on public.notifications
  for each row execute function public.guard_notification_recipient_update();

-- ── 4. appointments: a technician may only flip the status ────────────────
-- (appointments_update_own_technician exists so queueStartVisit can set
-- status='in_progress'; nothing else in the technician app writes here
-- directly.) Ops staff keep full write via appointments_write_ops.
create or replace function public.guard_appointment_technician_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') or pg_trigger_depth() > 1 then
    return new;
  end if;
  if old.technician_id = public.current_technician_id() and not public.is_ops_staff() then
    if (to_jsonb(new) - array['status', 'updated_at'])
       is distinct from (to_jsonb(old) - array['status', 'updated_at']) then
      raise exception 'appointments: technicians can only update the appointment status';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_guard_appointment_technician_update on public.appointments;
create trigger aa_guard_appointment_technician_update
  before update on public.appointments
  for each row execute function public.guard_appointment_technician_update();

-- ── 5. customer_members / addresses: org_id must be the caller's org ──────
drop policy if exists customer_members_write_own on public.customer_members;
create policy customer_members_write_own on public.customer_members
  for all using (customer_id = public.current_customer_id())
  with check (customer_id = public.current_customer_id() and org_id = public.current_org_id());

drop policy if exists addresses_write_own on public.addresses;
create policy addresses_write_own on public.addresses
  for all using (customer_id = public.current_customer_id())
  with check (customer_id = public.current_customer_id() and org_id = public.current_org_id());
