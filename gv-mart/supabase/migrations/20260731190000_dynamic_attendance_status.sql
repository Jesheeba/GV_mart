-- Admin Settings / Attendance audit, Task 1/2 — root cause: `attendance.
-- is_late` was computed CLIENT-SIDE, once, at check-in
-- (`src/app/technician/AttendancePage.tsx`'s `handleMark()`), against
-- `settings.late_cutoff` read through `useTechnicianSettings`/`getSettings`,
-- which falls back to an offline-first Dexie cache
-- (`src/lib/offline/db.ts`'s `settingsCache`) with no TTL and no
-- invalidation when the admin edits Settings. A technician whose device held
-- a stale cached `late_cutoff` (or was simply offline) at the moment of
-- check-in gets a permanently wrong `is_late` baked into the row — nothing
-- ever re-validates it server-side afterward. This is why a 03:23 PM
-- check-in against a 09:15 AM work start could still read "On Time": the
-- device's cached settings, not the admin's current configuration, decided
-- the answer, and it decided it once, forever.
--
-- Fix: move the computation server-side into a trigger that reads LIVE
-- settings on every write, so the stored value can never be more stale than
-- "whatever the admin has configured right now" — completely independent of
-- what the submitting client's cache believed. Also adds the 4-tier
-- Early/On Time/Late/Very Late classification Task 2 asks for, without
-- discarding the existing binary `is_late` (kept in sync by the same
-- trigger) so every existing consumer (OpsDashboard's on-time/late counts,
-- technician_late_hours HR function, admin attendance list/detail views)
-- keeps working unchanged.
--
-- Boundaries, all computed in Asia/Kolkata wall-clock time (same pattern
-- technician_late_hours already uses, so this is timezone-safe from day
-- one — never dependent on the submitting device's own clock/timezone):
--   check_in_at time  <  work_start                          -> early
--   work_start <= time <= late_cutoff                        -> on_time
--   late_cutoff < time <= late_cutoff + very_late_threshold   -> late
--   time > late_cutoff + very_late_threshold_minutes          -> very_late
--
-- late_cutoff is kept as its own admin-configurable field (it already has a
-- second, distinct purpose — the tick-checklist lock time, see
-- 20260701091100_system.sql's original comment) rather than collapsed into
-- work_start. What WAS a real gap is that nothing kept it sane relative to
-- work_start — added a CHECK constraint for that. very_late_threshold_minutes
-- is new: Task 2 needs a 4th tier with its own boundary, and per Task 1's
-- "no module keeps its own hardcoded timing" requirement, that boundary must
-- be admin-configurable too, not a hardcoded constant in this trigger.

alter table public.settings
  add column very_late_threshold_minutes integer not null default 120
    check (very_late_threshold_minutes > 0);

alter table public.settings
  add constraint settings_late_cutoff_after_work_start check (late_cutoff >= work_start);

alter table public.attendance
  add column status text not null default 'on_time'
    check (status in ('early', 'on_time', 'late', 'very_late'));

create or replace function public._attendance_compute_status()
returns trigger
language plpgsql
as $$
declare
  v_settings public.settings;
  v_time time;
begin
  if new.check_in_at is null then
    return new;
  end if;

  select * into v_settings from public.settings where org_id = new.org_id;
  if v_settings is null then
    -- No settings row (shouldn't happen in practice — every org gets one at
    -- creation) — leave the client-supplied/default values alone rather
    -- than raising and blocking a real check-in.
    return new;
  end if;

  v_time := (new.check_in_at at time zone 'Asia/Kolkata')::time;

  if v_time < v_settings.work_start then
    new.status := 'early';
  elsif v_time <= v_settings.late_cutoff then
    new.status := 'on_time';
  elsif v_time <= v_settings.late_cutoff + make_interval(mins => v_settings.very_late_threshold_minutes) then
    new.status := 'late';
  else
    new.status := 'very_late';
  end if;

  new.is_late := new.status in ('late', 'very_late');

  return new;
end;
$$;

drop trigger if exists attendance_compute_status on public.attendance;
create trigger attendance_compute_status
  before insert or update of check_in_at on public.attendance
  for each row execute function public._attendance_compute_status();

-- One-off backfill: recompute status/is_late for every existing row with a
-- check_in_at, using each org's current settings — the same "whatever the
-- admin has configured now, not whatever was cached at the time" fix,
-- applied retroactively so already-marked attendance isn't left showing a
-- stale, possibly-wrong on-time/late verdict.
update public.attendance a
set status = case
    when (a.check_in_at at time zone 'Asia/Kolkata')::time < s.work_start then 'early'
    when (a.check_in_at at time zone 'Asia/Kolkata')::time <= s.late_cutoff then 'on_time'
    when (a.check_in_at at time zone 'Asia/Kolkata')::time <= s.late_cutoff + make_interval(mins => s.very_late_threshold_minutes) then 'late'
    else 'very_late'
  end,
  is_late = (a.check_in_at at time zone 'Asia/Kolkata')::time > s.late_cutoff
from public.settings s
where s.org_id = a.org_id and a.check_in_at is not null;
