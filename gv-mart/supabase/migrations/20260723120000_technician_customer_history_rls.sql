-- STEP 6.1 / Meeting spec D6 ("History depth") — RLS gap fix.
--
-- customers_select_own_technician (20260704120000_technician_customer_address_rls.sql)
-- already lets a technician read a customer's row via ANY ticket they've
-- ever had an appointment on — current or past. But service_tickets_select_
-- own_technician (20260701091300_rls.sql) only grants a SPECIFIC ticket if
-- this technician has an appointment on THAT ticket. So a technician opening
-- today's job can see the customer's name, but not that customer's OTHER
-- tickets from an earlier visit a *different* technician handled — exactly
-- the "previous technician's notes" case D6 asks for (getCustomerHistory in
-- src/services/technician.ts, rendered on JobDetailPage's history card).
-- Same gap on service_visits (notes) and service_spares_used (parts
-- changed), which is where the actual D6 content lives.
--
-- SECURITY DEFINER (matching current_org_id()/current_technician_id() in
-- 20260701091200_functions_triggers.sql) so this bypasses RLS internally —
-- an inline `exists (select ... from service_tickets ...)` directly inside a
-- policy ON service_tickets would self-reference the same table and recurse
-- (see that migration's own comment on why the existing helpers are
-- SECURITY DEFINER).
create or replace function public.is_technician_customer(p_customer_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from service_tickets t
    join appointments a on a.ticket_id = t.id
    where t.customer_id = p_customer_id
      and a.technician_id = public.current_technician_id()
  )
$$;

create policy service_tickets_select_customer_history_technician on service_tickets
  for select using (public.is_technician_customer(customer_id));

create policy service_visits_select_customer_history_technician on service_visits
  for select using (
    exists (
      select 1 from service_tickets t
      where t.id = service_visits.ticket_id
        and public.is_technician_customer(t.customer_id)
    )
  );

create policy service_spares_used_select_customer_history_technician on service_spares_used
  for select using (
    exists (
      select 1 from service_visits v
      join service_tickets t on t.id = v.ticket_id
      where v.id = service_spares_used.visit_id
        and public.is_technician_customer(t.customer_id)
    )
  );
