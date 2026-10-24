// Build Order A4: a technician's active job (visit in progress) turning red
// once elapsed time passes the ticket's admin-set estimated duration.
//
// Pure so both the technician screens (red styling) and the admin live-map
// (overrun alert + notification) can share one definition of "overrun"
// instead of drifting — same rationale as isAmcRenewalOpen in
// src/lib/amc-window.ts, which this mirrors in shape/test style.

export interface JobOverrunInput {
  /** service_visits.timer_start — null/undefined means no visit is open yet. */
  timerStart: string | null | undefined
  /** service_visits.timer_end — a closed visit is never "overrunning". */
  timerEnd: string | null | undefined
  /**
   * service_tickets.estimated_duration_minutes — admin-set, nullable.
   * No overrun can be computed without it (see migration
   * 20260724120000_job_overrun_estimate.sql: no auto-population formula
   * exists yet, so plenty of tickets will legitimately have this null).
   */
  estimatedDurationMinutes: number | null | undefined
}

export interface JobOverrunResult {
  /** True only for an open visit whose elapsed time exceeds the estimate plus the grace buffer. */
  isOverrun: boolean
  /** Minutes elapsed since timer_start; null when there's no open visit. */
  elapsedMinutes: number | null
  /** elapsedMinutes - estimatedDurationMinutes, only when isOverrun; else null. */
  overrunByMinutes: number | null
}

const NOT_OVERRUN: JobOverrunResult = { isOverrun: false, elapsedMinutes: null, overrunByMinutes: null }

/**
 * Flat grace period on top of every job's estimate before it's flagged
 * overdue — a technician isn't red the instant the clock ticks past the
 * estimate, only once they're past the buffer. Applies uniformly to every
 * job/call site, not just one; this is the single place that grace period
 * is defined so it never drifts between the technician and admin screens.
 *
 * P5 (20261024110000): this used to be the only value. It is now the
 * fallback a caller passes when settings.job_overrun_buffer_minutes hasn't
 * loaded yet — every real call site passes the live setting instead.
 */
export const OVERRUN_BUFFER_MINUTES = 5

/**
 * Compares elapsed time on an in-progress visit against its ticket's
 * estimated duration plus the overrun buffer (settings.job_overrun_buffer_minutes,
 * passed in by the caller; see OVERRUN_BUFFER_MINUTES for the fallback).
 * Returns non-overrun (not "unknown") whenever the inputs can't support a
 * comparison — no open visit, or no estimate set — since "nothing to
 * compare against" must never render as red.
 */
export function computeJobOverrun(input: JobOverrunInput, nowMs: number = Date.now(), overrunBufferMinutes: number = OVERRUN_BUFFER_MINUTES): JobOverrunResult {
  const { timerStart, timerEnd, estimatedDurationMinutes } = input
  if (!timerStart || timerEnd) return NOT_OVERRUN
  if (estimatedDurationMinutes == null || estimatedDurationMinutes <= 0) return NOT_OVERRUN

  const threshold = estimatedDurationMinutes + overrunBufferMinutes
  const elapsedMinutes = (nowMs - new Date(timerStart).getTime()) / 60_000
  if (elapsedMinutes <= threshold) {
    return { isOverrun: false, elapsedMinutes, overrunByMinutes: null }
  }
  return { isOverrun: true, elapsedMinutes, overrunByMinutes: elapsedMinutes - estimatedDurationMinutes }
}
