-- v2.2 §6.5 TECH-05: "the technician searches the address, which shows the
-- customer name and contact number" — an org-wide search, not limited to the
-- technician's own assigned jobs (unlike the narrower
-- *_select_own_technician grants in 20260704120000). Read-only: fieldwork
-- needs technicians to find any customer by address to start a job, but
-- never to write customer/address data directly.
create policy customers_select_technician_search on customers
  for select using (org_id = public.current_org_id() and public.current_role() = 'technician');

create policy addresses_select_technician_search on addresses
  for select using (org_id = public.current_org_id() and public.current_role() = 'technician');
