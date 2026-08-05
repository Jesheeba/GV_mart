-- "Mark read" does nothing when clicked on a role-broadcast notification
-- (role is not null, user_id is null — the "exactly one of the two is set"
-- shape from notifications_user_or_role, 20260701091100_system.sql).
--
-- notifications_update_own (20260701091300_rls.sql) is `user_id = auth.uid()`
-- only. For a role-broadcast row user_id is always null, so that condition
-- is never true — the UPDATE is silently blocked by RLS (0 rows affected,
-- no error), so markNotificationRead()/markAllNotificationsRead()
-- (src/services/systemPages.ts) appear to succeed (the query invalidates
-- and refetches) but is_read never actually flips. Most notifications in
-- this app are role broadcasts (technician-assignment, AMC-sale, etc. all
-- target a role, not a specific user_id), so this affects the common case,
-- not an edge case.
--
-- Mirror notifications_select_own_role's visibility rule (extended in
-- 20260715100000 so master sees every role in their org): a user can mark
-- a role-broadcast notification read if it matches their own role, or if
-- they are master (org owner) and it's in their org. notifications_update_own
-- (user_id match) is untouched/unrelated.
--
-- Leaf table, no recursion risk (see 20260715100000's note — still true).
drop policy if exists notifications_update_own_role on notifications;
create policy notifications_update_own_role on notifications
  for update using (
    org_id = public.current_org_id()
    and role is not null
    and (role = public.current_role() or public.is_master())
  );
