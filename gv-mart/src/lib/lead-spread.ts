/**
 * Preview maths for "Set follow-up for selected -> spread N per day". The server (set_lead_followups_bulk) does the real
 * scheduling; this only tells the person what they are about to do: how many working days it takes and how the last
 * day looks. Mirrors the server: N leads a day, oldest first, one follow-up per lead.
 */
export function spreadPlan(leadCount: number, perDay: number): { days: number; lastDayCount: number } | null {
  if (!Number.isInteger(leadCount) || !Number.isInteger(perDay) || leadCount < 1 || perDay < 1) return null
  const days = Math.ceil(leadCount / perDay)
  const lastDayCount = leadCount - (days - 1) * perDay
  return { days, lastDayCount }
}

/** Server limits for one bulk call (set_lead_followups_bulk). */
export const BULK_MAX_LEADS = 200
export const BULK_MAX_PER_DAY = 100
export const BULK_DEFAULT_PER_DAY = 25

/** True when the per-day number is one the server accepts. */
export function isValidPerDay(value: string): boolean {
  if (!/^\d+$/.test(value.trim())) return false
  const n = Number(value)
  return n >= 1 && n <= BULK_MAX_PER_DAY
}

export type BulkSkipReason = "closed" | "has_followup" | "not_yours" | "not_found"

/** Counts of skipped leads per reason, for the result message. */
export function summariseSkipped(skipped: { reason: string }[]): Partial<Record<BulkSkipReason, number>> {
  const out: Partial<Record<BulkSkipReason, number>> = {}
  for (const s of skipped) {
    const r = s.reason as BulkSkipReason
    out[r] = (out[r] ?? 0) + 1
  }
  return out
}
