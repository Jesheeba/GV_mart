-- Rollback for 20261015130000_internal_tables_staff_read.sql: restores the open organisation-wide SELECT policies.
create policy automation_flows_select_org on public.automation_flows for select using (org_id = public.current_org_id());
drop policy if exists meeting_logs_select_staff_or_technician on public.meeting_logs;
create policy meeting_logs_select_org on public.meeting_logs for select using (org_id = public.current_org_id());
drop policy if exists meeting_issues_select_staff_or_technician on public.meeting_issues;
create policy meeting_issues_select_org on public.meeting_issues for select using (org_id = public.current_org_id());
