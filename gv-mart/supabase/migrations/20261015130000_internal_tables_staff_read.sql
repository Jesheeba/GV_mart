-- Review (phase 0, 2026-10-12): meeting_logs, meeting_issues and automation_flows had a SELECT policy of the form
-- "org_id = current_org_id()" with no role helper, so every member of the organisation (customers and technicians
-- included) could read internal meeting notes and automation rows.
--
--   * automation_flows: only admin screens read it (services/automation.ts); a staff-only SELECT policy already exists
--     (automation_flows_select_staff), so the open one is simply dropped.
--   * meeting_logs / meeting_issues: office staff, plus an ACTIVE technician (the technician Huddle page is a read-only
--     view of today's notes and open issues, src/app/technician/HuddlePage.tsx). Customers and anyone without a role
--     (including inactive staff after F-07) read nothing. Write policies are unchanged.

drop policy if exists automation_flows_select_org on public.automation_flows;

drop policy if exists meeting_logs_select_org on public.meeting_logs;
create policy meeting_logs_select_staff_or_technician on public.meeting_logs for select
  using (org_id = public.current_org_id() and (public.is_staff() or public.current_technician_is_active()));

drop policy if exists meeting_issues_select_org on public.meeting_issues;
create policy meeting_issues_select_staff_or_technician on public.meeting_issues for select
  using (org_id = public.current_org_id() and (public.is_staff() or public.current_technician_is_active()));
