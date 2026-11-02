-- "Pin my address" (customer dashboard). addresses.lat/lng already exist (used by staff's
-- AddressMapPicker and the customer app's own AddressForm, which already requires a pin on
-- add/edit) -- this migration only adds metadata and tightens validation that was missing.
--
-- Additive only:
--   - pinned_at: when the pin was last set/changed. Nullable -- null means no pin (or a pin set
--     before this column existed; backfilled to created_at/updated_at is NOT done here, since
--     there is no real record of when a pre-existing pin was actually placed -- null correctly
--     means "unknown/not tracked", not "just now").
--   - location_accuracy_m: the browser geolocation API's own reported accuracy in metres, when
--     the pin came from "Use my current location" (GeolocationCoordinates.accuracy). Null when
--     the pin came from search or a manual drag, which have no comparable accuracy figure.
--
-- Validation: lat/lng have had NO range check since they were added (20260701090200_customers.sql)
-- -- checked live data first (12,013 existing rows, zero out-of-range, zero one-set-one-null) --
-- safe to add directly, not NOT VALID. "Both or neither": a lat with no lng (or vice versa) is a
-- half-written pin, never a valid state.
alter table public.addresses add column pinned_at timestamptz;
alter table public.addresses add column location_accuracy_m numeric(10, 2);

alter table public.addresses add constraint addresses_lat_range check (lat is null or lat between -90 and 90);
alter table public.addresses add constraint addresses_lng_range check (lng is null or lng between -180 and 180);
alter table public.addresses add constraint addresses_lat_lng_both_or_neither check ((lat is null) = (lng is null));
alter table public.addresses add constraint addresses_accuracy_non_negative check (location_accuracy_m is null or location_accuracy_m >= 0);

-- No audit_log trigger is added for this table, on purpose -- same reasoning this project's own
-- staff_private table gives for not auditing an address: audit_log is readable by every staff
-- role, and a pinned location is exactly the kind of precise personal data that shouldn't be
-- copied into a broadly-readable audit trail. addresses.updated_at (already there) plus the new
-- pinned_at column are the record of "when", without ever duplicating the coordinates themselves
-- into a second, wider-readable table.
