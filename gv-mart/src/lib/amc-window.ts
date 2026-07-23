/**
 * AMC/warranty renewal booking-window math (settings.amc_book_window_days):
 * renewal opens once the due date is within `windowDays` days out — an
 * already-overdue due date (negative/zero `daysUntil`) is naturally still
 * within the window. No existing coverage (`dueDateStr` null/undefined)
 * means there's nothing to be "too early" for, so the window is always open.
 *
 * Extracted from CustomerAmcPage's local `windowInfo` closure so it's
 * testable without rendering the page — the component now just forwards to
 * this function with its own `bookWindowDays`/`today`.
 */
export function isAmcRenewalOpen(
  dueDateStr: string | null | undefined,
  windowDays: number,
  now: Date
): { withinWindow: boolean; daysUntil: number | null } {
  if (!dueDateStr) return { withinWindow: true, daysUntil: null }
  const due = new Date(dueDateStr)
  const daysUntil = Math.ceil((due.getTime() - now.getTime()) / (1000 * 60 * 60 * 24))
  return { withinWindow: daysUntil <= windowDays, daysUntil }
}

/**
 * `amc_plans.price` is a flat total for the plan's own `years` duration, not
 * a per-year rate — `price_per_year` (backfilled as `price / years` for any
 * plan created before that column existed) is the real per-year figure.
 * Single source of truth so every screen that shows or sums a "per year"
 * AMC amount agrees with each other — see Build Order Step 1.1/1.2.
 */
export function pricePerYearOf(plan: { price: number; years: number; price_per_year?: number | null }): number {
  return plan.price_per_year ?? Math.round((plan.price / Math.max(plan.years, 1)) * 100) / 100
}
