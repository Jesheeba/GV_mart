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
  /** True only for an open visit whose elapsed time exceeds the estimate. */
  isOverrun: boolean
  /** Minutes elapsed since timer_start; null when there's no open visit. */
  elapsedMinutes: number | null
  /** elapsedMinutes - estimatedDurationMinutes, only when isOverrun; else null. */
  overrunByMinutes: number | null
}

const NOT_OVERRUN: JobOverrunResult = { isOverrun: false, elapsedMinutes: null, overrunByMinutes: null }

/**
 * Compares elapsed time on an in-progress visit against its ticket's
 * estimated duration. Returns non-overrun (not "unknown") whenever the
 * inputs can't support a comparison — no open visit, or no estimate set —
 * since "nothing to compare against" must never render as red.
 */
export function computeJobOverrun(input: JobOverrunInput, nowMs: number = Date.now()): JobOverrunResult {
  const { timerStart, timerEnd, estimatedDurationMinutes } = input
  if (!timerStart || timerEnd) return NOT_OVERRUN
  if (estimatedDurationMinutes == null || estimatedDurationMinutes <= 0) return NOT_OVERRUN

  const elapsedMinutes = (nowMs - new Date(timerStart).getTime()) / 60_000
  if (elapsedMinutes <= estimatedDurationMinutes) {
    return { isOverrun: false, elapsedMinutes, overrunByMinutes: null }
  }
  return { isOverrun: true, elapsedMinutes, overrunByMinutes: elapsedMinutes - estimatedDurationMinutes }
}
