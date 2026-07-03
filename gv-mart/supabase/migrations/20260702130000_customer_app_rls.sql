-- Phase 8 (CUST-01..08): Customer App — RLS additions.
--
-- Two gaps identified against the Phase 1 policy set (20260701091300_rls.sql):
--
-- 1. `technician_locations` only has staff-select / own-technician-select /
--    own-technician-insert policies. CUST-07's live ETA tracking needs a
--    customer to read the location trail of the technician currently
--    assigned to one of THEIR OWN open tickets — nothing broader. Scoped via
--    an exists() subquery joining appointments -> service_tickets, mirroring
--    the existing `service_tickets_select_own_technician` join style.
--
-- 2. `automation_flows`/`video_library` are `*_select_staff` only. CUST-04's
--    topic chips need a customer to read `video_library` (asset by topic)
--    and `automation_flows` (trigger->action mapping) so the client can
--    resolve "which video/link to show for this chip" without a staff role.
--    Both are non-sensitive marketing content scoped by org_id — a plain
--    org-wide read for any authenticated org member (same pattern already
--    used for brands/models/products/spares/amc_plans in Phase 1).

-- ── technician_locations: customer can see their own open ticket's technician ──
create policy technician_locations_select_own_customer on technician_locations
  for select using (
    exists (
      select 1
      from appointments a
      join service_tickets t on t.id = a.ticket_id
      where a.technician_id = technician_locations.technician_id
        and a.status in ('scheduled', 'in_progress')
        and t.customer_id = public.current_customer_id()
    )
  );

-- ── automation_flows / video_library: readable org-wide (marketing content) ──
create policy automation_flows_select_org on automation_flows
  for select using (org_id = public.current_org_id());

create policy video_library_select_org on video_library
  for select using (org_id = public.current_org_id());
