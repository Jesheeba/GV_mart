-- Production-readiness audit 2026-09-23, Item 3: none of the three GitHub
-- Actions-driven cron functions (wa-scheduled-tasks, wa-milestone-dispatch,
-- technician-shift-reset) had any real alerting. Two problems, both live:
--   1. Per-task errors inside each function were caught with console.error
--      and swallowed — nobody watches Edge Function logs, and the function
--      still returned HTTP 200, so GitHub Actions showed green even when
--      the underlying work silently failed every tick.
--   2. If the GitHub Actions trigger itself stopped firing (wrong secret,
--      GH disabling a stale scheduled workflow, etc.), nothing would ever
--      notice — this is exactly how the CRON_SECRET/WA_CRON_SECRET mismatch
--      incident (2026-08-25) went undetected for its first run, and the
--      wa-milestone-dispatch.yml file sat uncommitted-and-unpicked-up for
--      weeks before that.
--
-- One small global (not per-org — technician-shift-reset in particular
-- processes every org in a single RPC call, it doesn't loop per org) table
-- that all three functions write a heartbeat to on every invocation,
-- success or failure. Kept separate from settings.*_last_run_at (which
-- stays as-is — that pair is genuinely per-org admin-configurable pacing,
-- a different concern from "did the cron infrastructure itself fire and
-- succeed").
create table public.cron_job_heartbeats (
  job_key text primary key,
  -- Nullable, no default: null genuinely means "this job has never recorded
  -- a completed run" (checkAndAlertStaleJobs treats that as maximally
  -- stale). A default of now() here would let a staleness-alert write that
  -- only touches last_stale_alert_at silently fabricate "just ran".
  last_run_at timestamptz,
  last_status text not null default 'ok' check (last_status in ('ok', 'error')),
  last_error text,
  last_stale_alert_at timestamptz
);

alter table public.cron_job_heartbeats enable row level security;

-- Read-only for master (a future admin view could surface this); all writes
-- are service-role only from the cron functions themselves, same shape as
-- whatsapp_provider_credentials post-Item-2 — this table has no org_id to
-- scope by (it's cross-org infra state), so it's master-only rather than
-- staff-visible.
create policy cron_job_heartbeats_select_master on public.cron_job_heartbeats
  for select using (public.is_master());
