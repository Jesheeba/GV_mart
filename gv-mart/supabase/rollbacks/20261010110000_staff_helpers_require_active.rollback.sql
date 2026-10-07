-- Rollback for 20261010110000_staff_helpers_require_active.sql.
-- These are the EXACT bodies that were live before the change (read from pg_proc on 2026-10-07):
-- security definer, stable, search_path = public, select current_role() in (...).
-- Grants are untouched by CREATE OR REPLACE, so nothing else needs restoring.
create or replace function public.is_sales_staff()
returns boolean language sql stable security definer set search_path to 'public' as $$
 select public.current_role() in ('master', 'sales_admin') $$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path to 'public' as $$
 select public.current_role() in ('master', 'operation_admin', 'sales_admin') $$;
