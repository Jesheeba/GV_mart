-- Rollback for held/20261015110000_current_role_active_gate.sql (F-07): restores the exact live bodies of 2026-10-12.
-- Restores the old behaviour in which an inactive master / operation_admin keeps full database access.
-- Order: current_role first (so nothing returns NULL), then helpers, policy, then drop the last-master trigger.

create or replace function public."current_role"()
returns public.user_role
language sql stable security definer set search_path to 'public'
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_master()
returns boolean
language sql stable security definer set search_path to 'public'
as $$ select public.current_role() = 'master' $$;

create or replace function public.is_ops_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$ select public.current_role() in ('master', 'operation_admin') $$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and (role in ('master', 'operation_admin') or (role = 'sales_admin' and is_active))
  )
$$;

create or replace function public.is_sales_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and (role = 'master' or (role = 'sales_admin' and is_active))
  )
$$;

drop policy if exists settings_select_org on public.settings;
create policy settings_select_org on public.settings for select
  using (org_id = public.current_org_id() and public."current_role"() is distinct from 'customer'::public.user_role);

drop trigger if exists profiles_last_master_update on public.profiles;
drop trigger if exists profiles_last_master_delete on public.profiles;
drop function if exists public._trg_profiles_last_master();
drop function if exists public._org_active_master_count(uuid, uuid);
