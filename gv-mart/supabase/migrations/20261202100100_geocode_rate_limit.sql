-- Per-user rate limit for the `geocode` Edge Function (address-from-location cost/abuse
-- follow-up). customer_auto_onboard (20261130100001) grants a 'customer' profile to ANY
-- Google sign-in with no vetting, so the geocode function's existing auth check ("any
-- signed-in role qualifies") is, in practice, open to anyone with a Google account -- this
-- predates and is not specific to the new "reverse" (Use my current location) action; it
-- applies equally to autocomplete/details/geocode/directions. This migration adds the one
-- server-side counter the Edge Function needs to cap it, covering all 5 actions from one
-- call site (the Edge Function change ships in a separate, later deploy -- not in this file).
--
-- Two windows per user, enforced together in one atomic upsert: burst (150 calls / 2 minutes)
-- and daily (2500 calls / day). Numbers are derived from this codebase's own timing constants
-- (debounce intervals, React Query staleTime/key-change behaviour), not live production
-- telemetry -- none exists. Headroom is ~3x over the worst *legitimate* pattern found by
-- inspection: NOT customer address entry, but a staff member actively watching the fleet
-- live-tracking map (TechniciansMapPage.tsx's useDirectionsDistance, keyed on each tracked
-- technician's position rounded to ~111m -- React Query's staleTime does not throttle this
-- when the key itself changes, so several actively-driving technicians under one dispatcher
-- can out-call any single customer's address-entry session by a wide margin).
--
-- Design: one row per user, continuously overwritten by the upsert below -- the table can
-- never hold more rows than there are distinct users who have ever called geocode, and the
-- daily pg_cron sweep at the bottom of this file drops rows nobody has touched in 2+ days, so
-- it never grows unbounded from one-time callers either.
--
-- clock_timestamp() throughout, deliberately NOT now()/transaction_timestamp(): now() is
-- frozen at the enclosing transaction's start for its entire duration, which is harmless for a
-- real Edge Function call (each RPC invocation is its own short transaction, so now() is fresh
-- each time in practice) but is flat-out wrong for window-elapsed math the moment more than one
-- check runs inside a single longer-lived transaction (as this migration's own rehearsal test
-- does, deliberately, to exercise a window reset without a real multi-minute sleep).
create table public.geocode_rate_limits (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  burst_window_start timestamptz not null default clock_timestamp(),
  burst_count integer not null default 0,
  day_window_start timestamptz not null default clock_timestamp(),
  day_count integer not null default 0,
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.geocode_rate_limits enable row level security;
-- No policies at all (default-deny), and no table-level grant to ANY API-facing role,
-- including service_role: nothing ever touches this table directly -- only the SECURITY
-- DEFINER function below does, and a SECURITY DEFINER function runs as its owner, not as the
-- caller's role, so it needs no grant on the table itself. Same lock-everything-down pattern
-- as profile_password_markers (20261102100000_p2_staff_profile_and_huddle.sql).
revoke all on public.geocode_rate_limits from public, anon, authenticated, service_role;

-- Atomic: a single INSERT ... ON CONFLICT DO UPDATE ... RETURNING, so two concurrent calls
-- from the same user (e.g. an autocomplete keystroke racing a details call) can never both
-- read a stale pre-increment count and both pass when only one of them should have.
create or replace function public.check_and_increment_geocode_rate_limit(
  p_user_id uuid,
  p_burst_window_seconds integer,
  p_burst_max integer,
  p_day_window_seconds integer,
  p_day_max integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_burst_count integer;
  v_day_count integer;
  v_now timestamptz := clock_timestamp();
begin
  insert into public.geocode_rate_limits (user_id, burst_window_start, burst_count, day_window_start, day_count, updated_at)
  values (p_user_id, v_now, 1, v_now, 1, v_now)
  on conflict (user_id) do update set
    burst_window_start = case when v_now - geocode_rate_limits.burst_window_start >= make_interval(secs => p_burst_window_seconds)
                               then v_now else geocode_rate_limits.burst_window_start end,
    burst_count = case when v_now - geocode_rate_limits.burst_window_start >= make_interval(secs => p_burst_window_seconds)
                        then 1 else geocode_rate_limits.burst_count + 1 end,
    day_window_start = case when v_now - geocode_rate_limits.day_window_start >= make_interval(secs => p_day_window_seconds)
                             then v_now else geocode_rate_limits.day_window_start end,
    day_count = case when v_now - geocode_rate_limits.day_window_start >= make_interval(secs => p_day_window_seconds)
                      then 1 else geocode_rate_limits.day_count + 1 end,
    updated_at = v_now
  returning burst_count, day_count into v_burst_count, v_day_count;

  return v_burst_count <= p_burst_max and v_day_count <= p_day_max;
end;
$$;

-- The Edge Function's service-role-keyed client is the only intended caller (PostgREST runs
-- this function AS its owner regardless, since it's SECURITY DEFINER -- this grant only
-- controls who may INVOKE it at all).
revoke execute on function public.check_and_increment_geocode_rate_limit(uuid, integer, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.check_and_increment_geocode_rate_limit(uuid, integer, integer, integer, integer) to service_role;

-- Cleanup: a user who calls once and never again would otherwise leave one stale row forever.
-- A daily sweep at a quiet hour (21:00 UTC = 02:30 IST) is cheap on a table this small and
-- reuses the project's existing pg_cron mechanism (same unschedule-then-schedule shape as
-- 20261007120000_lead_followup_notifications.sql).
create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.cleanup_geocode_rate_limits()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.geocode_rate_limits where updated_at < clock_timestamp() - interval '2 days';
$$;
revoke execute on function public.cleanup_geocode_rate_limits() from public, anon, authenticated;
grant execute on function public.cleanup_geocode_rate_limits() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'geocode-rate-limit-cleanup') then
    perform cron.unschedule('geocode-rate-limit-cleanup');
  end if;
  perform cron.schedule('geocode-rate-limit-cleanup', '0 21 * * *', 'select public.cleanup_geocode_rate_limits()');
end
$$;
