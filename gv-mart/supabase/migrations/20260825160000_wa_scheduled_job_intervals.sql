-- Admin-configurable pacing for the two WhatsApp cron-backed Edge
-- Functions (wa-milestone-dispatch, wa-scheduled-tasks). GitHub Actions
-- cron schedules live in committed YAML and can't read from a database, so
-- the standard pattern applies instead: the GH Actions trigger stays a
-- tight, fixed interval; each function checks these columns first and
-- no-ops (per org) if its configured interval hasn't elapsed yet.
--
-- Same "single source of truth" reasoning as the rest of this table
-- (20260701091100_system.sql's header comment) — no separate job-config
-- table, extended here the same way whatsapp_bot_enabled was.
alter table settings
  add column if not exists milestone_dispatch_enabled boolean not null default true,
  add column if not exists milestone_dispatch_interval_minutes integer not null default 5 check (milestone_dispatch_interval_minutes > 0),
  add column if not exists milestone_dispatch_last_run_at timestamptz,
  add column if not exists scheduled_tasks_enabled boolean not null default true,
  add column if not exists scheduled_tasks_interval_minutes integer not null default 1440 check (scheduled_tasks_interval_minutes > 0),
  add column if not exists scheduled_tasks_last_run_at timestamptz;
