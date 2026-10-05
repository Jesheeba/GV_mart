-- SECURITY FIX (found 2026-10-05 during customer Google-login verification).
--
-- 1. `profiles_insert_own` (id = auth.uid(), no other check) let ANY signed-in
--    account insert its own profile with role='master' + the real org_id.
-- 2. `profiles_update_own` (no WITH CHECK, no column guard) let any user
--    update their own role to 'master'.
-- 3. `customers_update_own` let a customer rewrite their own mobile/tags/
--    primary_profile_id/org_id.
-- 4. `settings_select_org` exposed internal config (discount caps, PO
--    threshold, office coordinates ...) to customers.
-- 5. anon could EXECUTE reset_stale_shift_end_prompts().
--
-- Writes made by SECURITY DEFINER functions (link_customer_google_account ...)
-- and by the service role (Edge Functions) must keep working. The guards
-- therefore key on `current_user`: inside a SECURITY DEFINER function it is
-- the function owner, for service-key calls it is service_role, and only
-- direct client (PostgREST) writes run as authenticated/anon. The guard
-- trigger functions are deliberately SECURITY INVOKER for that reason.

-- ── 1. Nobody creates their own profile any more ──────────────────────────
-- profiles_insert_master stays (master creates profiles in their org). The
-- customer link RPC and the admin-create-technician Edge Function insert as
-- definer/service_role and never needed this policy.
drop policy if exists profiles_insert_own on public.profiles;

-- ── 2. Guard privileged profile columns (INSERT and UPDATE) ───────────────
create or replace function public.guard_profile_privileged_columns()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- definer RPCs / service role / migrations: trusted
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if public.is_master() then
    if new.org_id is distinct from public.current_org_id() then
      raise exception 'profiles: cannot place a profile outside your organisation';
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    raise exception 'profiles: only master can create profiles from the client';
  end if;

  if new.id is distinct from old.id
     or new.org_id is distinct from old.org_id
     or new.role is distinct from old.role
     or new.staff_role_key is distinct from old.staff_role_key then
    raise exception 'profiles: role, organisation and salary role can only be changed by master';
  end if;

  -- nobody re-activates / deactivates themselves
  if old.id = auth.uid() and new.is_active is distinct from old.is_active then
    raise exception 'profiles: you cannot change your own active status';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_profile_privileged_columns on public.profiles;
create trigger guard_profile_privileged_columns
  before insert or update on public.profiles
  for each row execute function public.guard_profile_privileged_columns();

-- ── 3. Customers may only edit name/profession of their own record ────────
create or replace function public.guard_customer_self_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- only restrict the customer acting on their OWN row; staff writes
  -- (customers_write_sales) are untouched
  if old.id = public.current_customer_id() then
    if (to_jsonb(new) - array['name', 'profession', 'updated_at'])
       is distinct from (to_jsonb(old) - array['name', 'profession', 'updated_at']) then
      raise exception 'customers: you can only edit your name and profession here';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_customer_self_update on public.customers;
create trigger guard_customer_self_update
  before update on public.customers
  for each row execute function public.guard_customer_self_update();

-- ── 4. settings: not readable by customers; safe subset via RPC ───────────
drop policy if exists settings_select_org on public.settings;
create policy settings_select_org on public.settings
  for select using (
    org_id = public.current_org_id()
    and public.current_role() is distinct from 'customer'
  );

-- Exactly the fields the customer app reads (AMC window, review prompt,
-- EMI display, booking window defaults).
create or replace function public.get_customer_app_settings(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(t) from (
    select
      amc_book_window_days,
      review_link_min_stars,
      google_review_url,
      emi_enabled,
      emi_tenure_months,
      emi_disclaimer,
      work_start,
      work_end,
      narrow_window_threshold_minutes,
      default_duration_paid_minutes
    from public.settings
    where org_id = p_org_id
      and org_id = public.current_org_id()
  ) t
$$;

revoke execute on function public.get_customer_app_settings(uuid) from public, anon;
grant execute on function public.get_customer_app_settings(uuid) to authenticated;

-- ── 5. Grants ──────────────────────────────────────────────────────────────
-- Only ever called by the technician-shift-reset Edge Function (service role).
revoke execute on function public.reset_stale_shift_end_prompts() from public, anon, authenticated;
revoke execute on function public.list_my_ticket_technicians() from public, anon;
