-- Fix: "the newly generated technician also not getting their job."
--
-- Confirmed live (query against production data): two open, unassigned
-- tickets (required_skill='battery', created 2026-07-31 ~10:28-10:29 UTC)
-- got a 'noneAvailable' result at creation time because the only
-- technician checked in at that moment (e4b0986f, skills=['ac']) didn't
-- match. A second technician (73facd63, skills include 'battery') checked
-- in about 20 minutes later — but nothing ever re-scanned the backlog of
-- already-unassigned tickets against the newly-present technician. This is
-- the SAME category of gap as
-- 20260731150000_auto_assign_next_job_on_completion.sql (assignment only
-- ever runs forward from a ticket-side event — creation, or now
-- completion — never from a technician-side event): here the missing
-- trigger point is "a technician becomes present for the day" (first
-- check-in of a brand-new hire, or any technician's morning check-in on an
-- existing day), not job completion.
--
-- attendance rows are written by a raw client-side upsert through the
-- offline outbox (src/lib/offline/sync.ts), not a SECURITY DEFINER RPC —
-- so there is no server-side function call site to hook this into. A row
-- trigger on `attendance` itself is the right hook: it fires no matter how
-- the row got written (offline-outbox upsert, admin backfill, anything
-- future), and needs no frontend change.
--
-- Reuses _auto_assign_next_ticket_to_technician verbatim (same helper the
-- completion fix added) — it already assigns at most one ticket (matching
-- the one-open-appointment invariant), so firing it once per check-in
-- transition is correct; if more tickets are still waiting after that, the
-- technician's own next completion (or the next technician who checks in)
-- picks up the rest.

create or replace function public._on_attendance_present_assign_backlog()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only fire on the transition INTO "present today" (check_in_at set,
  -- check_out_at not set) — not on every unrelated column update to the
  -- row, and not re-fired on an update that leaves the technician's
  -- presence state unchanged.
  if new.check_in_at is not null and new.check_out_at is null
     and (tg_op = 'INSERT' or old.check_in_at is null or old.check_out_at is not null)
  then
    perform public._auto_assign_next_ticket_to_technician(new.org_id, new.technician_id);
  end if;
  return new;
end;
$$;

drop trigger if exists attendance_auto_assign_on_checkin on public.attendance;
create trigger attendance_auto_assign_on_checkin
  after insert or update of check_in_at, check_out_at on public.attendance
  for each row execute function public._on_attendance_present_assign_backlog();
