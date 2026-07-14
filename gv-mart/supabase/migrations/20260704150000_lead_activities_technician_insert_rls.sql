-- generate_enquiry_lead() (TECH-07 "Generate Enquiry") lets a technician
-- create a `leads` row via `leads_insert_own_technician`, then optionally
-- inserts a `lead_activities` note row when the technician fills in the
-- note field. `lead_activities` has only one write policy —
-- `lead_activities_write_sales`, gated on is_sales_staff() (master/
-- sales_admin) — so a technician's note insert always violates RLS,
-- aborting the whole SECURITY INVOKER function call with a 403 and losing
-- the leads row too (the note isn't optional in practice: whenever a
-- technician actually types one, the entire "Generate Enquiry" action
-- fails). Scoped like `leads_insert_own_technician`: a technician may only
-- attach an activity to a lead they themselves own.
create policy lead_activities_insert_own_technician on lead_activities
  for insert
  with check (
    org_id = public.current_org_id()
    and exists (
      select 1 from public.leads l
      where l.id = lead_activities.lead_id
        and l.owner_id = public.current_technician_id()
    )
  );
