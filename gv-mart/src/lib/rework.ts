// Rework rules shared by the admin and technician screens (build-docs/features/rework.md).
// The server is the authority on all of these; the app uses them only to show the right UI.

/** True when a job completed at `completedAt` can still be marked as rework (settings.rework_window_days). */
export function isWithinReworkWindow(completedAt: string | null | undefined, windowDays: number, now: Date = new Date()): boolean {
  if (!completedAt) return false
  const done = new Date(completedAt).getTime()
  if (Number.isNaN(done)) return false
  return now.getTime() - done <= windowDays * 24 * 60 * 60 * 1000
}

/**
 * Salary deduction for a month (owner P2): the first `freeCount` reworks cost nothing, every one after
 * costs `amount`. Not set by the master (either value null) = no deduction. Mirrors compute_salary.
 */
export function reworkPenalty(reworks: number, freeCount: number | null | undefined, amount: number | null | undefined): number {
  if (freeCount == null || amount == null) return 0
  return Math.max(reworks - freeCount, 0) * amount
}

export type ReworkChoice = "free" | "paid"

/** On-site: a rework is chargeable only when the technician chose Paid (server re-derives it from the bill). */
export function isReworkChargeable(choice: ReworkChoice | null): boolean {
  return choice === "paid"
}

/** Completion time used for the window check in the UI (server uses the invoice time). */
export function ticketCompletedAt(ticket: { updated_at: string; service_visits?: { timer_end: string | null }[] | null }): string {
  const ends = (ticket.service_visits ?? []).map((v) => v.timer_end).filter((x): x is string => !!x).sort()
  return ends[ends.length - 1] ?? ticket.updated_at
}
