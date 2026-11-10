-- Clean-address-form redesign (2026-11-03 stream), Step 1: adds the one
-- structured address field that had no column anywhere in this schema --
-- `sub_area` ("Sub Area" on clean_address_form.pdf, between Street/Cross
-- and Main Area). Every other field the redesign needed (door_no, plot_no,
-- building_name, street_cross, landmark, area, zone) already existed --
-- see 20260701090200_customers.sql, 20260915130000_address_building_fields.sql,
-- 20260702200000_technicians_admin_schema.sql. Mirrors
-- 20261103120000_address_water_household_fields.sql in every way: nullable,
-- additive, no default, no backfill, no RPC change (create_customer_with_details
-- is left untouched; a brand-new customer's primary address gets sub_area
-- written as a small follow-up update, same pattern as setAddressZone/
-- setAddressStructuredFields), no RLS change needed (addresses_write_sales/
-- addresses_write_own already govern the whole row, not per-column).
alter table public.addresses add column if not exists sub_area text;

comment on column public.addresses.sub_area is
  'Added 2026-12-04 — "Sub Area" field from clean_address_form.pdf, captured on the admin Customer form''s address step alongside door_no/plot_no/building_name/street_cross/landmark/area. Feeds into the composed full_address text (see src/lib/address.ts composeFullAddress) the same way those columns do.';
