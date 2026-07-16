-- Two independent RLS fixes.
--
-- 1. `service_visits` has RLS enabled (20260701091300_rls.sql) but no SELECT
--    policy for the customer role at all — only service_visits_select_staff
--    (staff) and service_visits_write_own_technician (the assigned
--    technician) exist. CustomerBookingDetailPage.tsx embeds
--    `service_visits(...)` in a PostgREST query to show the customer their
--    own rating and before/after photos; under RLS this silently returns
--    `[]` for the owning customer (not an error — the row just isn't
--    visible), even though the same row is visible when queried as staff.
--
--    Recursion check before adding this (the same bug class already caused
--    Postgres 42P17 once — see 20260710120000 + its follow-up fix
--    20260713093000, where a new appointments-customer policy queried
--    service_tickets while service_tickets_select_own_technician
--    (20260704110000) already queried appointments, closing a two-table
--    cycle that broke login org-wide once it reached the remote DB).
--    This new policy lives ON service_visits and reads service_tickets via
--    ticket_id. Checked every existing policy on service_tickets
--    (20260701091300_rls.sql: select_staff, select_own_customer,
--    select_own_technician, write_ops, insert_own_customer) and none of
--    them query service_visits — select_own_technician only queries
--    appointments. Checked every policy on appointments too (staff, own-
--    technician, write_ops, update_own_technician, and the customer policy
--    added in 20260713093000, which goes through the SECURITY DEFINER
--    helper public.customer_owns_appointment() and so bypasses RLS
--    internally rather than re-entering it) — none of those query
--    service_visits either, so the chain
--    service_visits -> service_tickets -> appointments never loops back to
--    service_visits. This is the exact same shape as the already-working
--    ratings_select_own_customer policy (service_visits join
--    service_tickets), just without the extra join, so a plain unwrapped
--    exists() is safe here — no SECURITY DEFINER wrapper needed.
drop policy if exists service_visits_select_own_customer on service_visits;
create policy service_visits_select_own_customer on service_visits
  for select using (
    exists (
      select 1 from service_tickets t
      where t.id = service_visits.ticket_id and t.customer_id = public.current_customer_id()
    )
  );

-- 2. notifications_select_own_role (20260701091300_rls.sql) requires an
--    *exact* role match (`role = current_role()`), so the master account —
--    the org owner — only ever sees notifications targeted at role='master'
--    and misses role='operation_admin'/'sales_admin' notifications (e.g.
--    AMC-sale and technician-assignment events) even though master should
--    reasonably see every role-targeted notification in their org. Extend
--    the policy so public.is_master() (20260701091200_functions_triggers.sql)
--    grants visibility into all role-targeted notifications for their own
--    org, in addition to the existing own-role match.
--
--    notifications is a leaf table — no policy on any other table queries
--    it — so widening this condition carries no recursion risk.
--    notifications_select_own_user (user_id match) is untouched/unrelated.
drop policy if exists notifications_select_own_role on notifications;
create policy notifications_select_own_role on notifications
  for select using (
    org_id = public.current_org_id()
    and (role = public.current_role() or public.is_master())
  );
