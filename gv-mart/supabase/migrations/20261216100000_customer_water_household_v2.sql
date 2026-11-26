-- Customer water & household v2 (build-docs/features/customer-water-household.md, owner decisions 2026-11-26).
--
-- 1. customers gains water_hardness_ppm and household_problems ("problems faced by the family", visible to all staff
--    and technicians like TDS/pH).
-- 2. The duplicate per-ADDRESS water store (20261103120000) is folded into the customers row and dropped. Create used
--    to write it, but nothing outside the customer form ever read it. Existing customer values always win, and
--    nothing is overwritten.
-- 3. Health condition is removed (owner: "drop from DB"): customer_health_profile, get_customer_health_condition,
--    stamp_customer_health_profile, household_health_level, settings.show_health_condition_to_technicians.
-- 4. guard_water_profile_edit_roles covers the two new columns, so operation_admin stays confined to the water
--    profile and other roles still can't touch it.
-- Run as one transaction. The rollback is in supabase/rollbacks/; restoring dropped data needs the pre-apply backup.

-- 1. new columns ----------------------------------------------------------------------------------------------------------
alter table public.customers
  add column water_hardness_ppm numeric(7, 2) check (water_hardness_ppm is null or water_hardness_ppm >= 0),
  add column household_problems text[] not null default '{}';

alter table public.customers
  add constraint customers_household_problems_check check (
    cardinality(household_problems) <= 10
    and array_position(household_problems, null) is null
    and '' <> all (household_problems)
    and char_length(array_to_string(household_problems, '')) <= 1000
  );

-- 2. fold the address copy into the customer row ------------------------------------------------------------------------
-- One address per customer: the primary, else the oldest. Free-text source maps onto the enum, and anything else
-- becomes 'other' with its text. Out-of-range numbers are skipped rather than failing the whole migration.
with src as (
  select distinct on (a.customer_id)
    a.customer_id,
    nullif(btrim(a.water_source), '') as source_text,
    a.water_tds,
    a.water_ph,
    nullif(btrim(a.health_condition), '') as health_text
  from public.addresses a
  where nullif(btrim(a.water_source), '') is not null
     or a.water_tds is not null
     or a.water_ph is not null
     or nullif(btrim(a.health_condition), '') is not null
  order by a.customer_id, a.is_primary desc, a.created_at
), mapped as (
  select
    customer_id,
    case
      when source_text is null then null
      when lower(source_text) in ('corporation', 'corporation water', 'metro', 'metro water') then 'corporation'::public.water_source_type
      when lower(regexp_replace(source_text, '\s+', '', 'g')) in ('borewater', 'borewell', 'bore') then 'borewater'::public.water_source_type
      else 'other'::public.water_source_type
    end as source_enum,
    left(source_text, 100) as source_text,
    case when water_tds between 0 and 9999 then water_tds end as tds,
    case when water_ph between 0 and 14 then water_ph end as ph,
    left(health_text, 100) as problem
  from src
)
update public.customers c
set
  water_source = coalesce(c.water_source, m.source_enum),
  water_source_other = case
    when c.water_source is null and m.source_enum = 'other' then m.source_text
    else c.water_source_other
  end,
  water_tds_ppm = coalesce(c.water_tds_ppm, m.tds),
  water_ph = coalesce(c.water_ph, m.ph),
  household_problems = case
    when cardinality(c.household_problems) = 0 and m.problem is not null then array[m.problem]
    else c.household_problems
  end
from mapped m
where m.customer_id = c.id;

alter table public.addresses
  drop column water_source,
  drop column water_tds,
  drop column water_ph,
  drop column health_condition;

-- 3. health condition removed -------------------------------------------------------------------------------------------
drop function public.get_customer_health_condition(uuid);
drop table public.customer_health_profile;           -- its policies and stamp trigger go with it
drop function public.stamp_customer_health_profile();
drop type public.household_health_level;
alter table public.settings drop column show_health_condition_to_technicians;

-- 4. edit guard covers the new columns ----------------------------------------------------------------------------------
-- Same body as 20261108100000. Only the column lists grow.
create or replace function public.guard_water_profile_edit_roles()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_role public.user_role;
  v_water_changed boolean;
  v_other_changed boolean;
  v_water_cols constant text[] := array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'water_hardness_ppm', 'household_problems'];
begin
  if auth.uid() is null then
    return new;
  end if;

  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
    or new.water_hardness_ppm is distinct from old.water_hardness_ppm
    or new.household_problems is distinct from old.household_problems
  );

  v_other_changed := (
    (to_jsonb(new) - (v_water_cols || array['updated_at']))
    is distinct from
    (to_jsonb(old) - (v_water_cols || array['updated_at']))
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_role is distinct from 'sales_admin' and v_water_changed then
    raise exception 'customers: only master, operation_admin or sales_admin may edit the water profile fields';
  end if;

  return new;
end;
$$;

notify pgrst, 'reload schema';
