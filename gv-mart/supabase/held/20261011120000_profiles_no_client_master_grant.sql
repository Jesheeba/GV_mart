-- HELD (review F-06): no client-side write may set profiles.role to 'master', not even a master's.
-- Until now guard_profile_privileged_columns returned early for a master, so a master (or a stolen master token)
-- could create a sales_admin and then PATCH its role to 'master' through PostgREST, planting a persistent second
-- master. Masters are created or promoted only by the service role / the dashboard (current_user not in
-- authenticated/anon). A master's own row staying 'master' is untouched (the trigger fires only when the role changes
-- to master, or on insert).
-- SECURITY INVOKER on purpose: current_user must be the calling database role.

create or replace function public.guard_profile_no_client_master()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon')
     and new.role = 'master'
     and (tg_op = 'INSERT' or old.role is distinct from 'master') then
    raise exception 'profiles: a master can only be created or promoted by the service role or the dashboard';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_profile_no_client_master on public.profiles;
create trigger guard_profile_no_client_master
  before insert or update of role on public.profiles
  for each row execute function public.guard_profile_no_client_master();

revoke all on function public.guard_profile_no_client_master() from public, anon, authenticated;
