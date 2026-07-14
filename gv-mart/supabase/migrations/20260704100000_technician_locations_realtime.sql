-- v2.2 §6.6 live tracking: the admin map and customer LiveTracking widget
-- both subscribe to `postgres_changes` INSERT events on technician_locations,
-- but a table only emits those events once it's a member of the
-- `supabase_realtime` publication. That membership has never been captured
-- in a migration (likely dashboard-toggled, if set at all) — this makes it
-- reproducible and idempotent so a fresh environment doesn't silently ship a
-- tracking feature that never receives a single live update.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'technician_locations'
  ) then
    alter publication supabase_realtime add table technician_locations;
  end if;
end $$;
