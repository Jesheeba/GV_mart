-- Technicians have never had any write grant on `appointments` — only
-- `appointments_write_ops` (master/operation_admin) exists. This silently
-- no-ops queueStartVisit's `.update({status: "in_progress"})` call for every
-- technician, every time, both in the original manual "Start visit" flow and
-- the new arrival-triggered auto-start (v2.2 §6.6): the write reaches
-- PostgREST, matches zero rows under RLS, and returns success with no error
-- to catch, so the appointment silently stays "scheduled" forever.
--
-- Scoped to UPDATE only (not service_visits' broader "for all" precedent):
-- technicians only ever need to flip the status of their own already-
-- assigned appointment, never to insert or delete appointment rows.
create policy appointments_update_own_technician on appointments
  for update using (technician_id = public.current_technician_id())
  with check (technician_id = public.current_technician_id());
