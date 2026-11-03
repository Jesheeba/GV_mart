-- Rollback for 20261103120000_address_water_household_fields.sql.
alter table public.addresses drop column if exists water_source;
alter table public.addresses drop column if exists water_tds;
alter table public.addresses drop column if exists water_ph;
alter table public.addresses drop column if exists health_condition;
