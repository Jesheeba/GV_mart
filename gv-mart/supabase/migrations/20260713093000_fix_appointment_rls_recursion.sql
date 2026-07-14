-- Fixes an infinite-recursion bug (Postgres 42P17) introduced by
-- 20260710120000_customer_appointment_technician_rls.sql. That migration's
-- three new "customer can see their own technician's appointment info"
-- policies did plain joins straight into `appointments`/`service_tickets`
-- inside a `using (...)` clause. That closed a cycle with the existing
-- service_tickets_select_own_technician policy (20260704110000), which
-- itself queries `appointments`:
--   appointments RLS -> queries service_tickets
--   service_tickets RLS -> queries appointments
-- Postgres detects this at plan time and every query touching either table
-- (including a plain `select * from profiles where id = ...` at login,
-- since profiles_select_by_customer pulls in technicians -> appointments)
-- fails with "infinite recursion detected in policy for relation
-- appointments" — breaking login/RLS entirely once this migration reached
-- the remote database.
--
-- Fix: move each policy's exists()-subquery into its own SECURITY DEFINER
-- function, matching the existing current_org_id()/current_customer_id()
-- pattern (see 20260701091200_functions_triggers.sql) — those bypass RLS
-- internally (function owner is the superuser migration role), so a query
-- routed through one of these never re-triggers RLS on the tables it reads,
-- breaking the cycle while keeping the exact same access rules.

create or replace function public.customer_owns_appointment(p_ticket_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.service_tickets t
    where t.id = p_ticket_id and t.customer_id = public.current_customer_id()
  )
$$;

create or replace function public.customer_sees_technician(p_technician_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.appointments a
    join public.service_tickets t on t.id = a.ticket_id
    where a.technician_id = p_technician_id and t.customer_id = public.current_customer_id()
  )
$$;

create or replace function public.customer_sees_technician_profile(p_profile_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.technicians tech
    join public.appointments a on a.technician_id = tech.id
    join public.service_tickets t on t.id = a.ticket_id
    where tech.profile_id = p_profile_id and t.customer_id = public.current_customer_id()
  )
$$;

drop policy if exists appointments_select_own_customer on appointments;
create policy appointments_select_own_customer on appointments
  for select using (public.customer_owns_appointment(appointments.ticket_id));

drop policy if exists technicians_select_by_customer on technicians;
create policy technicians_select_by_customer on technicians
  for select using (public.customer_sees_technician(technicians.id));

drop policy if exists profiles_select_by_customer on profiles;
create policy profiles_select_by_customer on profiles
  for select using (public.customer_sees_technician_profile(profiles.id));
