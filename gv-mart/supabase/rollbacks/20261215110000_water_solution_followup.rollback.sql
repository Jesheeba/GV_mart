-- Rollback for 20261215110000_water_solution_followup.sql. Refuses if any recommended solution was saved, rather
-- than silently discarding it. Follow-up tasks already created stay as ordinary tasks (nothing is deleted); only
-- the dedupe index, the RPCs, the reminder job and the column go.
do $$
begin
  if exists (select 1 from public.customers where water_recommended_solution is not null) then
    raise exception 'rollback refused: customers.water_recommended_solution already holds data -- export it first';
  end if;
  if exists (select 1 from cron.job where jobname = 'water-followup-due') then
    perform cron.unschedule('water-followup-due');
  end if;
end $$;

drop function public.notify_due_water_followups();
drop function public.close_water_followup_as_lead(uuid, uuid);
drop function public.postpone_water_followup(uuid, date, text);
drop function public.get_customer_water_followup(uuid);
drop function public.set_customer_water_followup(uuid, date);
drop function public._water_followup_description(public.customers);
drop function public._water_followup_today();
drop function public._water_followup_caller_ok();
drop index public.tasks_water_followup_one_open_idx;

-- guard back to the 20261215100000 version (6 water columns) before the column goes
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

alter table public.customers drop column water_recommended_solution;

notify pgrst, 'reload schema';
