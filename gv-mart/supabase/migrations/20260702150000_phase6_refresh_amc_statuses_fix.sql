-- Fix: refresh_amc_statuses (20260702110100_service_amc_functions.sql) failed
-- every call with "column \"status\" is of type amc_status but expression is
-- of type text" — the SET clause's CASE returns untyped string literals
-- ('expired'/'due_soon'/'active') with no cast, while the WHERE clause's
-- identical CASE already has the `::amc_status` cast it was missing. Same
-- fix, applied to both branches for clarity.
create or replace function public.refresh_amc_statuses(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window integer;
begin
  if not public.is_ops_staff() then
    raise exception 'refresh_amc_statuses: only master or operation_admin may run this';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'refresh_amc_statuses: org mismatch';
  end if;

  select amc_book_window_days into v_window from public.settings where org_id = p_org_id;
  v_window := coalesce(v_window, 15);

  update public.amc_contracts
  set status = (case
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end)::amc_status
  where org_id = p_org_id and status is distinct from (case
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end)::amc_status;
end;
$$;
