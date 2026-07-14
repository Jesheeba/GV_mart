-- Fixes a gap left by 20260702130000_customer_app_rls.sql: that migration
-- correctly scoped `technician_locations` for a customer's live tracking,
-- but missed that `appointments` itself — and the assigned `technicians`/
-- `profiles` rows needed to show the technician's name/phone — had no
-- customer-facing select policy at all (only *_select_staff /
-- *_select_own_technician existed). Every customer-app query that embeds
-- `appointments(...)` (CustomerBookingsPage's date label, CustomerBooking-
-- DetailPage's "Scheduled for {date}" + Technician card + the live-tracking
-- gate itself, which reads `appointment.status`) was silently getting back
-- an empty array under RLS — not an error, just nothing — so a booking made
-- with a specific date/time displayed as "Anytime" and the technician card
-- never appeared, regardless of what was actually stored.

-- ── appointments: customer can see appointments on their own tickets ──
create policy appointments_select_own_customer on appointments
  for select using (
    exists (
      select 1 from service_tickets t
      where t.id = appointments.ticket_id and t.customer_id = public.current_customer_id()
    )
  );

-- ── technicians: customer can see a technician assigned to one of their own appointments ──
create policy technicians_select_by_customer on technicians
  for select using (
    exists (
      select 1
      from appointments a
      join service_tickets t on t.id = a.ticket_id
      where a.technician_id = technicians.id and t.customer_id = public.current_customer_id()
    )
  );

-- ── profiles: customer can see the name/phone of a technician assigned to one of their own appointments ──
create policy profiles_select_by_customer on profiles
  for select using (
    exists (
      select 1
      from technicians tech
      join appointments a on a.technician_id = tech.id
      join service_tickets t on t.id = a.ticket_id
      where tech.profile_id = profiles.id and t.customer_id = public.current_customer_id()
    )
  );
