-- Requirement 7 — real Attendance check-out flow. Attendance previously only
-- ever recorded a check-in (`check_in_at`); nothing captured when a
-- technician's day actually ended, so "hours worked" had to be estimated
-- rather than measured. Same additive pattern as the lunch_start/lunch_end
-- columns (20260702170500_lunch_and_calls.sql): a nullable timestamp patched
-- in later via the same offline-queued update flow, not a NOT NULL column
-- requiring a backfill.

alter table public.attendance
  add column if not exists check_out_at timestamptz;
