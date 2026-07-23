-- Build Order Group A / A4: technician job-overrun indicator + admin alert.
--
-- GAP FOUND (flagged per task instructions rather than silently invented):
-- the task brief assumed `service_tickets.estimated_duration_minutes`
-- "already exists, auto-set by product/ticket-type" via `_detect_ticket_type`
-- or a related trigger. It does not — grepped every migration and
-- src/types/database.ts: no `estimated_duration_minutes`,
-- `service_time`/`item_service_time`, or `review`/`enquiry` time-allowance
-- concept exists anywhere in this schema. `_detect_ticket_type`
-- (20260702110100_service_amc_functions.sql) only classifies AMC/Warranty/
-- Paid — it has nothing to do with duration. There is also no "item service
-- time" master data table to derive a formula from (products only carry
-- name/category/price/warranty_months; settings has no per-type minutes
-- column).
--
-- Since inventing that formula (admin-set item service times + review/
-- enquiry allowances, auto-computed per product/ticket-type) was explicitly
-- out of scope ("if they don't yet, that's a real gap worth flagging, not
-- silently inventing a new allowance formula"), this migration adds ONLY the
-- storage column, nullable, with no auto-population trigger. Until a real
-- "item service time" master + allowance formula is specified and built,
-- admins set it by hand per ticket (src/app/admin/service/TicketDetailPage.tsx)
-- and the overrun feature simply has nothing to compare against (no overrun
-- possible) for any ticket where it's left null — same "absence of data
-- means no alert" behavior settings.sla_hours_* nulls already produce
-- elsewhere in this codebase (see getSlaSettings in src/services/service.ts).
--
-- COLLISION NOTE (found live-verifying via supabase-js, 2026-07-23): the
-- remote project already has a `service_tickets.estimated_duration_minutes`
-- integer column (nullable, all rows null, no check constraint) even though
-- no migration file defining it exists anywhere in this branch's git history
-- — almost certainly a parallel Group-A agent's worktree pushed it directly
-- to the shared remote DB without committing the migration file yet (see
-- MEMORY.md "GV Mart parallel migration collisions"). `add column if not
-- exists` / a guarded constraint below make this migration safe to apply
-- either way — on a fresh DB that doesn't have the column yet, or replayed
-- against this shared remote project where it already does.
alter table service_tickets
  add column if not exists estimated_duration_minutes integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'service_tickets'::regclass
      and conname = 'service_tickets_estimated_duration_minutes_check'
  ) then
    alter table service_tickets
      add constraint service_tickets_estimated_duration_minutes_check
      check (estimated_duration_minutes is null or estimated_duration_minutes > 0);
  end if;
end $$;

comment on column service_tickets.estimated_duration_minutes is
  'Admin-set expected duration (minutes) for the on-site visit, compared against service_visits.timer_start elapsed time to flag an overrunning job (Build Order A4). Nullable and manually set — no auto-population formula exists yet (see migration header note); a null value means overrun detection is skipped for that ticket.';
