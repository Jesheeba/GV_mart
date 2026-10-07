-- Staff helpers require is_active for sales_admin (approved 2026-10-07). Rollback: supabase/rollbacks/20261010110000_staff_helpers_require_active.rollback.sql
--
-- A deactivated sales_admin must lose staff-level access immediately, not when the
-- access token expires (up to ~1h after a ban + session revoke). current_role() ignores
-- profiles.is_active, so is_staff() and is_sales_staff() treated an inactive sales_admin
-- as full staff. Only sales_admin gains the is_active requirement:
--   master, operation_admin, technician, customer rows evaluate EXACTLY as before
--   (the demo operation_admin is inactive today and must behave as before).
-- Same attributes as the existing helpers (security definer, stable, search_path=public),
-- so grants and policy plans are unchanged.
-- Not changed (and why): is_master / is_ops_staff do not include sales_admin. ~24 RPCs
-- test current_role() directly; a banned + revoked session is their barrier (see report).

create or replace function public.is_sales_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and (role = 'master' or (role = 'sales_admin' and is_active))
  )
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and (role in ('master', 'operation_admin') or (role = 'sales_admin' and is_active))
  )
$$;
