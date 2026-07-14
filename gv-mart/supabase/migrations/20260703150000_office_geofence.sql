-- v2.2 §6.8: attendance geofence must compare against an admin-set office
-- location, not a hardcoded constant. `geofence_radius_m` already existed;
-- the office coordinate itself was a literal in src/services/technician.ts
-- (OFFICE_LOCATION) with no admin control. This makes it a real,
-- admin-editable setting alongside the radius. Default matches the prior
-- hardcoded placeholder (Chennai) so existing behavior doesn't regress
-- until the admin sets the real office coordinates via Settings.
alter table settings
  add column office_lat numeric(9, 6) not null default 13.0827 check (office_lat >= -90 and office_lat <= 90),
  add column office_lng numeric(9, 6) not null default 80.2707 check (office_lng >= -180 and office_lng <= 180);
