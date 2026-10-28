-- Rollback for 20261113100000_close_spare_handover_technician_rls_hole.sql.
-- NOT applied to any database; this file has not been run.
--
-- Unlike the sibling 20261114100000 rollback, this one does NOT need a data-safety refusal
-- check: nothing here drops a column or any other structure that could hold data that would
-- be destroyed by restoring it. Every change this migration made was a privilege change
-- (RLS policy identity + one function's SECURITY mode) -- re-opening the hole does not delete,
-- overwrite, or expose anything that is not already fully present and intact in the live rows
-- (spare_handovers / spare_handover_items keep every row and column either way; restoring the
-- permissive policy only changes who may write to them going forward). A straightforward,
-- unconditional restore is therefore safe. (The one thing the original hole lets back in --
-- a technician being able to insert a fake handover row directly -- is a FUTURE risk this
-- rollback re-introduces, not a destructive action against anything that already exists.)

drop policy if exists spare_handovers_select_own_technician on public.spare_handovers;

create policy spare_handovers_write_own_technician on public.spare_handovers for all
  using (technician_id = public.current_technician_id())
  with check (technician_id = public.current_technician_id());

drop policy if exists spare_handover_items_select_own_technician on public.spare_handover_items;

create policy spare_handover_items_write_own_technician on public.spare_handover_items for all
  using (exists (select 1 from spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id()))
  with check (exists (select 1 from spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id()));

-- Restore confirm_spare_handover to its exact pre-this-migration body: `security invoker`,
-- no `set search_path`, relying on spare_handovers_write_own_technician (just restored above)
-- for its UPDATE to be visible -- the exact live body from
-- 20260702120000_technician_phase7_functions.sql.
create or replace function public.confirm_spare_handover(
  p_handover_id uuid,
  p_tech_sign_url text,
  p_admin_sign_url text
)
returns void
language plpgsql
security invoker
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'confirm_spare_handover: caller is not a technician';
  end if;
  if nullif(p_tech_sign_url, '') is null or nullif(p_admin_sign_url, '') is null then
    raise exception 'confirm_spare_handover: both technician and admin signatures are required';
  end if;

  update public.spare_handovers
    set tech_sign_url = p_tech_sign_url, admin_sign_url = p_admin_sign_url, status = 'confirmed'
    where id = p_handover_id and technician_id = v_tech_id;

  if not found then
    raise exception 'confirm_spare_handover: handover % not found for this technician', p_handover_id;
  end if;
end;
$$;

grant execute on function public.confirm_spare_handover(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
