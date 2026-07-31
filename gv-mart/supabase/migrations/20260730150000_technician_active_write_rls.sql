-- Technician lifecycle management, Phase 3: a deactivated technician's own
-- session could still write new attendance/location/visit/handover data,
-- because current_technician_id() never checked is_active (only
-- profile_id = auth.uid()). Assignment eligibility was already fixed
-- (20260730130000); this closes the matching gap on the write side — "only
-- active technicians should have access to operational data." Read
-- policies are untouched: history must stay visible per the task's own
-- global requirement, this only gates creating NEW rows.

create or replace function public.current_technician_is_active()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select is_active from public.technicians where id = public.current_technician_id()), false)
$$;

alter policy attendance_write_own_technician on public.attendance
  using (technician_id = public.current_technician_id() and public.current_technician_is_active())
  with check (technician_id = public.current_technician_id() and public.current_technician_is_active());

alter policy technician_locations_insert_own on public.technician_locations
  with check (technician_id = public.current_technician_id() and public.current_technician_is_active());

alter policy service_visits_write_own_technician on public.service_visits
  using (technician_id = public.current_technician_id() and public.current_technician_is_active())
  with check (technician_id = public.current_technician_id() and public.current_technician_is_active());

alter policy service_sop_steps_write_own_technician on public.service_sop_steps
  using (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );

alter policy service_spares_used_write_own_technician on public.service_spares_used
  using (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );

alter policy ro_checklists_write_own_technician on public.ro_checklists
  using (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );

alter policy ratings_write_own_technician on public.ratings
  using (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );

alter policy spare_handovers_write_own_technician on public.spare_handovers
  using (technician_id = public.current_technician_id() and public.current_technician_is_active())
  with check (technician_id = public.current_technician_id() and public.current_technician_is_active());

alter policy spare_handover_items_write_own_technician on public.spare_handover_items
  using (
    exists (select 1 from public.spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );
