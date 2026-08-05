-- Customer Dashboard: persistent "technician assigned" banner (CustomerShell)
-- subscribes to postgres_changes UPDATE on service_tickets so a status
-- transition (assigned/in_progress -> completed, or a fresh assignment)
-- shows/hides the banner immediately instead of waiting for the next poll.
-- Same idempotent pattern as 20260704100000_technician_locations_realtime.sql
-- and 20260725110000_otp_completion_confirmation.sql's service_visit_otps
-- addition — a table only emits postgres_changes once it's a member of the
-- supabase_realtime publication.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_tickets'
  ) then
    alter publication supabase_realtime add table service_tickets;
  end if;
end $$;
