-- Rollback for 20261102100000_staff_profile_fields_and_huddle_attribution.sql
-- Drops the new objects and columns. Data written to the dropped columns is lost; the notifications rows already
-- written stay (they are ordinary rows).
drop function if exists public.get_profile_address(uuid);
-- dropping the address column below removes the REVOKE with it; no explicit re-grant needed.

drop function if exists public.raise_huddle_issue(text);

drop trigger if exists meeting_issue_notify_master_upd on public.meeting_issues;
drop trigger if exists meeting_issue_notify_master_ins on public.meeting_issues;
drop function if exists public._meeting_issue_notify_master();

drop trigger if exists aa_meeting_issue_attribution on public.meeting_issues;
drop function if exists public._meeting_issue_attribution();
alter table public.meeting_issues drop column if exists solved_by, drop column if exists solution_by;

drop function if exists public.acknowledge_password_change();
drop trigger if exists guard_profile_staff_fields on public.profiles;
drop function if exists public.guard_profile_staff_fields();
alter table public.profiles
  drop column if exists colour,
  drop column if exists must_change_password,
  drop column if exists address,
  drop column if exists designation;
