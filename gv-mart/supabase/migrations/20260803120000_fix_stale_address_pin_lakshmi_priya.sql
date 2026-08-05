-- Data-only fix: address 1c48a7ee-b3b7-4d65-9be1-42e4e32d332d (Lakshmi
-- Priya, "32, Hastinapuram main road") was edited on 2026-07-21 from its
-- original seed text ("12, Thyagaraya Street", T. Nagar) to the real address,
-- but its lat/lng were never re-geocoded — they were still the seed's T.
-- Nagar centroid (13.0418, 80.2341), ~17km from the real Hastinapuram/
-- Chromepet location. That stale pin is what the technician's "Open in
-- Maps" button and live distance/ETA card were plotting.
--
-- This was a genuine gap in both address-edit forms (AddressForm.tsx,
-- CustomerFormPage.tsx): editing the address text didn't invalidate an
-- already-confirmed pin, so nothing prompted a re-check. That gap is fixed
-- in the app code separately; this migration is the one-off data correction
-- for the row it already broke. Corrected value from Google's Geocoding API
-- for "32, Hastinapuram main road, Chennai".
update addresses
set lat = 12.9445011,
    lng = 80.1416407
where id = '1c48a7ee-b3b7-4d65-9be1-42e4e32d332d';
