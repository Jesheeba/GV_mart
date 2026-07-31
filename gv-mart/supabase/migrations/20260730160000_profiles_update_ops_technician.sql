-- Technician Lifecycle Management, Phase 2: editing a technician's
-- phone/photo (both live on `profiles`, not `technicians`) needs an
-- operation_admin caller to be able to update someone else's profile row.
-- The existing `profiles_update_master` policy only covers `master` —
-- everywhere else in the Technicians module (zone/skills/capacity/active
-- toggle on `technicians` itself) is scoped to is_ops_staff() (master OR
-- operation_admin, 20260701091300_rls.sql:100-102), so this closes that one
-- narrow gap rather than widening `profiles` access generally: ops-staff can
-- only update a profile that both belongs to their org AND is a technician
-- (not another admin's own profile).

create policy profiles_update_ops_technician on public.profiles
  for update
  using (org_id = public.current_org_id() and public.is_ops_staff() and role = 'technician')
  with check (org_id = public.current_org_id() and public.is_ops_staff() and role = 'technician');
