-- Technicians have never been able to read a customer's name/phone or
-- address for their own assigned job: `addresses` and `customers` only had
-- `_select_staff` (staff roles) and `_select_own` (the customer themself)
-- policies — no technician-scoped grant existed at all (unlike
-- service_tickets, which had one, just a broken one — see
-- 20260704110000). This silently empties the `customers(...)`/`addresses(*)`
-- embeds in getJobDetail/listTodaysJobs for every technician, on every job,
-- always (not just this one ticket) — the technician's own name/number/
-- address display and TECH-04 map navigation destination have been unable
-- to resolve real data since these tables' RLS was first written.
--
-- Scoped narrowly, mirroring service_tickets_select_own_technician: only the
-- customer/address tied to a ticket the technician currently has an
-- appointment on — not a company-wide "any technician can see any
-- customer" grant. (TECH-05's searchAddressesForTechnician wants broader,
-- org-wide address search for technicians and is a separate, deliberately
-- unaddressed gap — a wider grant is a product/privacy decision, not a bug
-- fix, and needs sign-off before broadening technician visibility to every
-- customer in the org.)
create policy addresses_select_own_technician on addresses
  for select using (
    exists (
      select 1 from service_tickets t
      join appointments a on a.ticket_id = t.id
      where t.address_id = addresses.id and a.technician_id = public.current_technician_id()
    )
  );

create policy customers_select_own_technician on customers
  for select using (
    exists (
      select 1 from service_tickets t
      join appointments a on a.ticket_id = t.id
      where t.customer_id = customers.id and a.technician_id = public.current_technician_id()
    )
  );
