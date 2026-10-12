-- HELD (review F-07, approved): an inactive master, operation_admin or sales_admin has no role. One choke point.
--
-- Findings from the live catalog (2026-10-12) that changed the original design:
--   * is_staff() and is_sales_staff() read profiles DIRECTLY, not through current_role(), so changing current_role() alone
--     would have left an inactive master/operation_admin with is_staff() = true. They are rewritten here.
--   * is_master() / is_ops_staff() return NULL (not false) when current_role() is NULL. About 40 functions guard with
--     "if not public.is_master() then raise ..." and "if not (is_ops_staff() or is_sales_staff()) then raise ...": a NULL
--     makes the whole condition NULL, the IF is skipped and the guard FAILS OPEN. Both are made strict booleans here, in
--     the same migration, before current_role() is allowed to return NULL.
--   * settings_select_org used "current_role() IS DISTINCT FROM 'customer'": NULL IS DISTINCT FROM 'customer' is true, so
--     an inactive staff member would still read internal settings. Fixed.
-- Technicians and customers are deliberately untouched (technicians are gated by technicians.is_active, a customer
-- profile's is_active has a different meaning).
--
-- Apply order inside this one transaction: (1) strict-boolean helpers, (2) staff helpers, (3) policy, (4) last-master
-- trigger, (5) current_role(). The last-master trigger protects the organisation from locking itself out.

-- ── 1. is_master / is_ops_staff: never NULL ────────────────────────────────────────────────────────────────────────────
create or replace function public.is_master()
returns boolean
language sql stable security definer set search_path to 'public'
as $$ select coalesce(public.current_role() = 'master', false) $$;

create or replace function public.is_ops_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$ select coalesce(public.current_role() in ('master', 'operation_admin'), false) $$;

-- ── 2. is_staff / is_sales_staff: every office role must be active ─────────────────────────────────────────────────────
create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and role in ('master', 'operation_admin', 'sales_admin')
       and is_active
  )
$$;

create or replace function public.is_sales_staff()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and role in ('master', 'sales_admin')
       and is_active
  )
$$;

-- ── 3. settings_select_org: a NULL role must not read internal settings ────────────────────────────────────────────────
drop policy if exists settings_select_org on public.settings;
create policy settings_select_org on public.settings for select
  using (org_id = public.current_org_id()
         and public.current_role() is not null
         and public.current_role() <> 'customer');

-- ── 4. never leave an organisation without an active master ────────────────────────────────────────────────────────────
-- Counts other active masters with definer rights (RLS must not hide a colleague from the count).
create or replace function public._org_active_master_count(p_org uuid, p_except uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::integer from public.profiles
   where org_id = p_org and role = 'master' and is_active and id is distinct from p_except
$$;
revoke all on function public._org_active_master_count(uuid, uuid) from public, anon, authenticated;

-- SECURITY INVOKER on purpose: current_user must be the calling role for the break-glass check.
-- Applies to every caller including the service role. Exempt: organisations that are already gone (cascade delete),
-- __TEST_ throwaway organisations, and a DBA who sets app.allow_last_master_change = '1' as the postgres role.
create or replace function public._trg_profiles_last_master()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if tg_op = 'DELETE' then
    if old.role is distinct from 'master' or not old.is_active then
      return old;
    end if;
    v_org := old.org_id;
  else
    if not (old.role = 'master' and old.is_active) then
      return new;
    end if;
    if new.role = 'master' and new.is_active and new.org_id = old.org_id then
      return new;
    end if;
    v_org := old.org_id;
  end if;

  if not exists (select 1 from public.organizations where id = v_org) then
    return case when tg_op = 'DELETE' then old else new end;        -- organisation cascade
  end if;
  if exists (select 1 from public.organizations where id = v_org and name like '\_\_TEST\_%' escape '\') then
    return case when tg_op = 'DELETE' then old else new end;        -- throwaway test organisation
  end if;
  if current_user = 'postgres' and coalesce(current_setting('app.allow_last_master_change', true), '') = '1' then
    return case when tg_op = 'DELETE' then old else new end;        -- documented DBA break-glass
  end if;

  if public._org_active_master_count(v_org, old.id) = 0 then
    raise exception 'profiles: the last active master of an organisation cannot be deactivated, demoted, moved or deleted';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
revoke all on function public._trg_profiles_last_master() from public, anon, authenticated;

drop trigger if exists profiles_last_master_update on public.profiles;
create trigger profiles_last_master_update
  before update of is_active, role, org_id on public.profiles
  for each row execute function public._trg_profiles_last_master();
drop trigger if exists profiles_last_master_delete on public.profiles;
create trigger profiles_last_master_delete
  before delete on public.profiles
  for each row execute function public._trg_profiles_last_master();

-- ── 5. the choke point ─────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function public."current_role"()
returns public.user_role
language sql stable security definer set search_path to 'public'
as $$
  select case
           when role in ('master', 'operation_admin', 'sales_admin') and not is_active then null
           else role
         end
    from public.profiles
   where id = auth.uid()
$$;
