// FEATURE_TECHNICIAN_LEAVE_REQUEST.md §2.3: a day only counts as protected leave if the request
// was approved AND created at least `leave_notice_days` days before the leave's start date. This
// is only ever a PREVIEW for a still-pending request's "In advance" / "Late" badge — the database
// (decide_technician_leave's call to _leave_request_is_protected) is the only place the real
// `protected` flag is ever set; the front end never writes it.
export function isInAdvance(createdAt: string, startDate: string, noticeDays: number): boolean {
  const createdDate = new Date(createdAt).toISOString().slice(0, 10)
  const cutoff = new Date(startDate)
  cutoff.setDate(cutoff.getDate() - noticeDays)
  return createdDate <= cutoff.toISOString().slice(0, 10)
}

/** Inclusive day count between two "YYYY-MM-DD" dates. */
export function daysBetween(start: string, end: string): number {
  return Math.round((new Date(end).getTime() - new Date(start).getTime()) / 86_400_000) + 1
}
