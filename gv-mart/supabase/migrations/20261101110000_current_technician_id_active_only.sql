-- P1b: current_technician_id() resolves only an ACTIVE technician.
--
-- Until now the helper returned the technician row id for any technicians.profile_id = auth.uid(), active or
-- not; 20260730150000 patched that one policy at a time with current_technician_is_active(). Making the base
-- helper itself active-only closes every remaining policy and function that tested only "is not null" or an id
-- match.
--
-- What does NOT change (they do not use this helper):
--   * technicians_select_own (profile_id = auth.uid()) and the profiles row: a deactivated technician can
--     still sign in and still reads their own technicians row, so the "Account deactivated" screen
--     (TechnicianShell) still renders.
--   * every staff policy (is_staff() / is_ops_staff()), including admin_override_visit_completion.
--   * current_technician_is_active(): it calls this helper and coalesces to false, same answer as before.
--
-- Effect, by design: a deactivated technician resolves to NULL, so (a) the 36 policies / 19 functions listed in
-- design-note P1b return no rows / are refused for them, and (b) those functions' own
-- "caller is not a technician" guards fire. A queued offline job from a technician deactivated mid-job fails and
-- goes to the stuck list; it is not silently dropped, and an admin can close the visit.

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() and is_active $$;
