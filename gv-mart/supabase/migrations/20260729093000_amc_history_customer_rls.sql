-- Customer AMC page redesign needs a per-product "AMC history + parts used"
-- view (listMyAmcContractHistory in services/customerApp.ts). service_spares_used
-- is already populated correctly by create_service_invoice() for every visit
-- invoice, AMC included, but has no SELECT policy for the customer role at
-- all (20260701091300_rls.sql:296-303 only covers is_staff() and the
-- assigned technician) — a customer session gets `[]` even though the rows
-- exist.
--
-- Recursion check (same class of bug as 20260710120000/20260713093000):
-- grepped every policy on service_visits and service_tickets
-- (20260701091300_rls.sql, 20260704110000_fix_technician_ticket_rls.sql,
-- 20260715100000_service_visits_customer_rls_and_notification_role_fix.sql,
-- 20260723120000_technician_customer_history_rls.sql) — none of them query
-- service_spares_used, so this new policy (service_spares_used ->
-- service_visits -> service_tickets) cannot loop back. Same shape as the
-- already-working ratings_select_own_customer and
-- service_visits_select_own_customer policies, just one hop longer.
create policy service_spares_used_select_own_customer on service_spares_used
  for select using (
    exists (
      select 1 from service_visits v
      join service_tickets t on t.id = v.ticket_id
      where v.id = service_spares_used.visit_id
        and t.customer_id = public.current_customer_id()
    )
  );
