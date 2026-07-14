-- Fixes service_tickets_select_own_technician (20260701091300_rls.sql), which
-- has never actually granted access: its exists() subquery's unqualified
-- `id` resolves to appointments.id (the row's own primary key, since the
-- subquery's own FROM-list is the closest scope), not the intended outer
-- service_tickets.id — so the condition silently reduced to
-- `a.ticket_id = a.id`, which is never true for real UUIDs. This is why a
-- technician's own "today's jobs" list, job detail page, and map
-- destination resolution have been silently returning zero rows for tickets
-- that genuinely belong to them (no error — RLS just filters the row out).
drop policy if exists service_tickets_select_own_technician on service_tickets;
create policy service_tickets_select_own_technician on service_tickets
  for select using (
    exists (
      select 1 from appointments a
      where a.ticket_id = service_tickets.id and a.technician_id = public.current_technician_id()
    )
  );
