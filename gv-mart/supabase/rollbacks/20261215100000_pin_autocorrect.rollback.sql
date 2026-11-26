-- Rollback for 20261215100000_pin_autocorrect.sql.
-- Corrected pins stay where they are (they are real on-site readings); only the feature is removed.
drop function if exists public.record_technician_pin_correction(uuid, uuid, numeric, numeric, numeric);

delete from public.address_location_events where event = 'corrected';
alter table public.address_location_events drop constraint address_location_events_event_check;
alter table public.address_location_events
  add constraint address_location_events_event_check check (event in ('verified', 'reset'));

alter table public.settings drop column if exists pin_autocorrect_max_m;
