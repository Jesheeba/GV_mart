-- Lead security fixes (Phase 1, commit 1).
--
-- 1. leads_write_sales was FOR ALL, so it also granted DELETE to sales_admin.
--    The delete_lead RPC (20261005120000) assumes only the master can delete a
--    lead; a direct `delete from leads` by sales_admin bypassed it. Split into
--    insert + update policies and give leads NO delete policy at all — delete
--    stays master-only through the delete_lead SECURITY DEFINER RPC.
-- 2. Customers and technicians could insert a lead with any status (e.g.
--    'won'), inflating conversion numbers. Their direct-insert policies now
--    require status = 'new'.
-- 3. History must be append-only: lead_activities and lead_items had FOR ALL
--    sales policies too (sales_admin could rewrite/delete history directly).
--    Replaced with insert (+ update for lead_items, whose rows are edited as
--    the enquiry is refined) — nothing grants DELETE or, for activities,
--    UPDATE. Cascade from delete_lead (SECURITY DEFINER) is unaffected.

-- ── leads ────────────────────────────────────────────────────────────────
drop policy if exists leads_write_sales on public.leads;

create policy leads_insert_sales on public.leads
  for insert
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy leads_update_sales on public.leads
  for update
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

drop policy if exists leads_insert_own_technician on public.leads;
create policy leads_insert_own_technician on public.leads
  for insert
  with check (owner_id = public.current_technician_id() and status = 'new');

drop policy if exists leads_insert_own_customer on public.leads;
create policy leads_insert_own_customer on public.leads
  for insert
  with check (customer_id = public.current_customer_id() and status = 'new');

-- ── lead_activities (append-only) ────────────────────────────────────────
drop policy if exists lead_activities_write_sales on public.lead_activities;

create policy lead_activities_insert_sales on public.lead_activities
  for insert
  with check (org_id = public.current_org_id() and public.is_sales_staff());

-- ── lead_items (no delete) ───────────────────────────────────────────────
drop policy if exists lead_items_write_sales on public.lead_items;

create policy lead_items_insert_sales on public.lead_items
  for insert
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy lead_items_update_sales on public.lead_items
  for update
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());
