-- Admin/Technician notification bell (useUnreadNotificationCount) now holds
-- a postgres_changes subscription on `notifications` so a new row (e.g. a
-- job just auto-assigned) shows up within moments instead of waiting out the
-- 30s poll. Same idempotent pattern as 20260805140000_service_tickets_realtime.sql
-- -- a table only emits postgres_changes once it's a member of the
-- supabase_realtime publication.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table notifications;
  end if;
end $$;
