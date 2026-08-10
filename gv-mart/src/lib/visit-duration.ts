// Shared "how long did this visit take" formatting — was duplicated
// independently in TicketDetailPage.tsx, TechnicianDetailPage.tsx,
// HistoryDetailPage.tsx, and reports.ts before this. Sibling to
// job-overrun.ts/job-allowance.ts, which this is conceptually part of.

/** Minutes between two ISO timestamps, or null if either is missing. Never negative. */
export function minutesBetween(start: string | null | undefined, end: string | null | undefined): number | null {
  if (!start || !end) return null
  return Math.max(0, Math.round((new Date(end).getTime() - new Date(start).getTime()) / 60_000))
}

/**
 * Prefers a persisted `actual_duration_minutes` (set at close time by
 * verify_visit_otp/admin_override_visit_completion — see
 * 20260807120000_visit_actual_duration.sql) over live computation from
 * timer_start/timer_end, so a visit closed before that migration still shows
 * a number. Live computation is ONLY a fallback for pre-migration rows —
 * never re-derive a duration for a row that already has the persisted
 * figure, or it could silently drift (e.g. after an admin later edits
 * estimated_duration_minutes — the persisted figure reflects what was true
 * at close time and must not change).
 */
export function resolveVisitDurationMinutes(
  visit: { timer_start: string | null; timer_end: string | null; actual_duration_minutes?: number | null } | null | undefined
): number | null {
  if (!visit) return null
  return visit.actual_duration_minutes ?? minutesBetween(visit.timer_start, visit.timer_end)
}

/** "1h 32m" / "45m" formatting. */
export function formatDurationMinutes(totalMinutes: number): string {
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}
