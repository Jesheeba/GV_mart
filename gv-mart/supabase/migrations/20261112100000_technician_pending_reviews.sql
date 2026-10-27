-- Technician "Pending reviews" list (2026-11-12).
--
-- Display-only feature: a technician's own dashboard shows customers from HIS OWN completed visits
-- (service_visits.technician_id = his technicians.id, timer_end not null -- the same "completed" test
-- get_technician_public_stats already uses) who have NOT yet left a rating (no row in public.ratings
-- for that visit, per ratings.visit_id's own unique-per-visit constraint). Nothing is sent, emailed or
-- messaged from this -- it is a read-only follow-up list for the technician to act on in person.
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
    and not exists (
      select 1 from public.ratings r where r.visit_id = sv.id
    )
  order by sv.timer_end desc
$$;

revoke all on function public.list_technician_pending_reviews() from public, anon, authenticated;
grant execute on function public.list_technician_pending_reviews() to authenticated;
