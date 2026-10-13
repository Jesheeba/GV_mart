-- Rollback for 20261018150000_start_travel.sql. Drops the stamp column: the record of when each technician started travel is lost.
begin;
drop function if exists public.start_travel(uuid);
alter table public.appointments drop column if exists travel_started_at;
alter table public.settings drop column if exists automation_default_travel_eta_minutes;
update public.automation_events set has_emitter = false where event_key = 'technician.on_the_way';
commit;
