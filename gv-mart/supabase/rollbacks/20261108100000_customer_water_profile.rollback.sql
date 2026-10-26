-- Rollback for 20261108100000_customer_water_profile.sql. Refuses if any profile data has
-- already been entered (water columns on customers, any customer_health_profile row, or the
-- technician-visibility setting flipped on) rather than silently discarding it.
do $$
declare
  v_water_rows bigint;
  v_health_rows bigint;
  v_setting_flipped bigint;
begin
  select count(*) into v_water_rows
  from public.customers
  where water_source is not null
     or water_source_other is not null
     or water_tds_ppm is not null
     or water_ph is not null;

  select count(*) into v_health_rows from public.customer_health_profile;

  select count(*) into v_setting_flipped
  from public.settings
  where show_health_condition_to_technicians is true;

  if v_water_rows > 0 then
    raise exception 'rollback refused: % customers row(s) already have water profile data entered', v_water_rows;
  end if;
  if v_health_rows > 0 then
    raise exception 'rollback refused: % customer_health_profile row(s) already exist', v_health_rows;
  end if;
  if v_setting_flipped > 0 then
    raise exception 'rollback refused: % org(s) already turned on show_health_condition_to_technicians', v_setting_flipped;
  end if;
end $$;

revoke all on function public.get_customer_health_condition(uuid) from public, anon, authenticated;
drop function public.get_customer_health_condition(uuid);

revoke all on public.customer_health_profile from authenticated;
drop policy if exists customer_health_profile_select_own on public.customer_health_profile;
drop policy if exists customer_health_profile_staff_update on public.customer_health_profile;
drop policy if exists customer_health_profile_staff_insert on public.customer_health_profile;
drop policy if exists customer_health_profile_staff_select on public.customer_health_profile;
drop trigger if exists stamp_customer_health_profile on public.customer_health_profile;
drop function if exists public.stamp_customer_health_profile();
drop table public.customer_health_profile;

drop type household_health_level;

alter table public.settings
  drop column show_health_condition_to_technicians;

drop policy if exists customers_write_operation_admin on public.customers;
drop trigger if exists guard_water_profile_edit_roles on public.customers;
drop function if exists public.guard_water_profile_edit_roles();

alter table public.customers
  drop constraint if exists customers_water_source_other_only_with_other;

alter table public.customers
  drop column water_ph,
  drop column water_tds_ppm,
  drop column water_source_other,
  drop column water_source;
