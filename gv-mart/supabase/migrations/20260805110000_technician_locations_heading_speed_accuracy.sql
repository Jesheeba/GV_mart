-- Premium Live Tracking — persist the device's own heading/speed/accuracy
-- alongside each GPS fix, instead of only ever deriving bearing client-side
-- from consecutive lat/lng points (src/lib/tracking/geo.ts's bearingDegrees).
-- All three are nullable: navigator.geolocation's coords.heading/coords.speed
-- are frequently null (device not moving fast enough to report a heading,
-- or a sensor that doesn't support it) — never block a location write on
-- their absence, same "a stale/missing field is fine, a missing write isn't"
-- philosophy pingLiveLocation already documents for the write itself.
alter table public.technician_locations
  add column if not exists heading numeric(5, 1),
  add column if not exists speed numeric(6, 2),
  add column if not exists accuracy numeric(7, 2);

comment on column public.technician_locations.heading is 'Degrees clockwise from true north, from GeolocationCoordinates.heading. Null when the device has no heading (stationary/unsupported).';
comment on column public.technician_locations.speed is 'Meters/second, from GeolocationCoordinates.speed. Null when unavailable.';
comment on column public.technician_locations.accuracy is 'Meters, from GeolocationCoordinates.accuracy.';
