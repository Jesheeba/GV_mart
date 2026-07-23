-- Build Order Group A / A4: technician job-overrun indicator + admin alert.
--
-- CORRECTION during merge with main (2026-07-24): this migration was
-- authored in a worktree branched before `20260721090000_technician_
-- assignment_phase1_data.sql` (Phase 1 of the assignment engine rework)
-- landed on main, so this file's original header incorrectly claimed
-- `estimated_duration_minutes` and any auto-population "did not exist
-- anywhere in the schema." It does: that migration added the column
-- AND a `_service_tickets_derive_skill_and_duration()` trigger that
-- auto-fills it from `settings.default_duration_{paid,warranty,amc,
-- installation}_minutes` by ticket TYPE, for every insert path, unless a
-- caller already supplied a value. The (mistaken) "COLLISION NOTE" that
-- used to be here — theorizing a parallel agent had pushed the column
-- directly without a migration file — is removed; the real explanation is
-- simply that this branch was stale and hadn't merged main yet.
--
-- What genuinely IS still missing, and remains correctly flagged rather
-- than invented: the existing trigger only varies duration by ticket TYPE,
-- not by the more granular "review/enquiry allowances" the Build Order
-- brief mentions, and there's no per-item/per-product "item service time"
-- master table — only four org-wide type defaults in `settings`. If A4's
-- overrun detection needs to be more granular than "paid vs warranty vs amc
-- vs installation," that formula still needs to be specified.
--
-- This migration's actual remaining contribution: a `> 0` check constraint
-- (the existing column had none) and the admin manual-override UI/RPC on
-- `TicketDetailPage.tsx` — both purely additive on top of the existing
-- column and trigger, not a replacement for them. `estimated_duration_
-- minutes` will already be populated for the great majority of tickets via
-- the Phase 1 trigger; the manual editor is an override path, not the
-- primary source.
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
  'Expected duration (minutes) for the on-site visit — auto-populated by type via _service_tickets_derive_skill_and_duration() (Phase 1), admin-overridable per ticket. Compared against service_visits.timer_start elapsed time to flag an overrunning job (Build Order A4). A null value (population failed, or caller explicitly passed null) means overrun detection is skipped for that ticket.';
