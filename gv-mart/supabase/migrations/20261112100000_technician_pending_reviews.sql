-- Technician "Pending reviews" list (2026-11-12).
--
-- Display-only feature: a technician's own dashboard shows customers from HIS OWN completed visits
-- (service_visits.technician_id = his technicians.id, timer_end not null -- the same "completed" test
-- get_technician_public_stats already uses) who have NOT yet left a rating (no row in public.ratings
-- for that visit, per ratings.visit_id's own unique-per-visit constraint). Nothing is sent, emailed or
-- messaged from this -- it is a read-only follow-up list for the technician to act on in person.
--
-- Two additional filters (2026-11-13 review):
--   * Test customers excluded via `not c.is_test` -- this codebase already flags throwaway/demo
--     customers (`customers.is_test`, 20261016110000_test_customer_flag.sql) and keeps them out of
--     real figures everywhere else (incentives, reports); this list is no exception. Deliberately NOT
--     `public.is_test_customer(c.id)` (that migration's own helper): it is `security definer` but its
--     EXECUTE grant is `service_role` only (20261016110000_test_customer_flag.sql:39-41) -- calling it
--     from this function, which is `security invoker` on purpose (see above), would raise "permission
--     denied" for every real technician, since the invoker here is `authenticated`, not service_role.
--     Reading `c.is_test` directly off the already-joined, already-RLS-visible `customers` row needs no
--     extra grant and has identical semantics.
--   * Only visits completed in the last 60 days -- `sv.timer_end` compared against IST midnight 60
--     days before today's IST date (Asia/Kolkata), so the cutoff is a calendar-day boundary in the
--     technician's own timezone, not a bare 1440-hour window that would silently drift with UTC/IST
--     offset or daylight-adjacent edge cases (IST itself has no DST, but every other date computation
--     in this codebase that matters to a person -- incentive months, shift-end prompts -- is anchored
--     to Asia/Kolkata for the same reason: calendar days must mean the same thing the technician sees
--     on his own clock).
--
-- Strict ownership (technician B must never see technician A's customers) is enforced at the data layer,
-- not just hidden in the UI, two ways at once:
--   1. SECURITY INVOKER: this function carries no elevated privilege of its own -- every table it reads
--      (service_visits, service_tickets, customers, ratings) is read under the CALLER's own role and is
--      already subject to that table's real RLS (service_visits_write_own_technician restricts SELECT on
--      service_visits to technician_id = current_technician_id(); customers_select_own_technician and
--      service_tickets_select_own_technician/_customer_history_technician likewise scope the join tables --
--      see 20260701091300_rls.sql, 20260704120000_technician_customer_address_rls.sql,
--      20260723120000_technician_customer_history_rls.sql). A technician cannot make this function return
--      another technician's row even by bypassing the app, because the underlying SELECT privilege simply
--      isn't there for that row.
--   2. An explicit `sv.technician_id = public.current_technician_id()` filter in the function body itself,
--      as defense in depth on top of (1) and so a non-technician caller (current_technician_id() = null)
--      always gets zero rows rather than relying on RLS alone.
-- Every column referenced inside the query is table-qualified (sv./t./c./r.) to avoid the exact class of
-- ambiguous-column bug a bare `technician_id` or `visit_id` could introduce once this function is read
-- alongside sibling tables that share those column names.

-- The caller gets only name, job type and completion date -- never the customer's phone number.
-- This is a display-only follow-up list (no call/WhatsApp action anywhere downstream), so the
-- mobile column is deliberately left out of the result rather than fetched and merely hidden by
-- the UI -- the same "don't expose what the screen must not show" posture as this project's other
-- technician-facing reads.
create or replace function public.list_technician_pending_reviews()
returns table (
  visit_id uuid,
  ticket_id uuid,
  customer_id uuid,
  customer_name text,
  complaint text,
  visit_completed_at timestamptz
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select
    sv.id as visit_id,
    sv.ticket_id,
    t.customer_id,
    c.name as customer_name,
    t.name_of_complaint as complaint,
    sv.timer_end as visit_completed_at
  from public.service_visits sv
  join public.service_tickets t on t.id = sv.ticket_id
  join public.customers c on c.id = t.customer_id
  where sv.technician_id = public.current_technician_id()
    and sv.timer_end is not null
    and sv.timer_end >= (((now() at time zone 'Asia/Kolkata')::date - 60)::timestamp at time zone 'Asia/Kolkata')
    and not c.is_test
    and not exists (
      select 1 from public.ratings r where r.visit_id = sv.id
    )
  order by sv.timer_end desc
$$;

revoke all on function public.list_technician_pending_reviews() from public, anon, authenticated;
grant execute on function public.list_technician_pending_reviews() to authenticated;
