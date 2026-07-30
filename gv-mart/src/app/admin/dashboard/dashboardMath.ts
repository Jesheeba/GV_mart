import type { DateRange } from "@/services/reports"

/** Last `n` calendar months (oldest first) ending at the given anchor month, each as a full-month DateRange. */
export function lastNMonthsEnding(year: number, month: number, n: number): { label: string; range: DateRange }[] {
  const months: { label: string; range: DateRange }[] = []
  for (let i = n - 1; i >= 0; i--) {
    const from = new Date(year, month - 1 - i, 1)
    const to = new Date(year, month - i, 0)
    months.push({
      label: from.toLocaleDateString("en-IN", { month: "short" }),
      range: { from: from.toISOString().slice(0, 10), to: to.toISOString().slice(0, 10) },
    })
  }
  return months
}

/** Last `n` calendar months (oldest first), each as a full-month DateRange, ending with the current month. */
export function lastNMonths(n: number): { label: string; range: DateRange }[] {
  const now = new Date()
  return lastNMonthsEnding(now.getFullYear(), now.getMonth() + 1, n)
}

/** All 12 calendar months of `year` (Jan first), each as a full-month DateRange — used for Year-mode P&L rendering. */
export function monthsOfYear(year: number): { label: string; range: DateRange }[] {
  return lastNMonthsEnding(year, 12, 12)
}

export function thisMonthRange(): DateRange {
  const now = new Date()
  const from = new Date(now.getFullYear(), now.getMonth(), 1)
  return { from: from.toISOString().slice(0, 10), to: now.toISOString().slice(0, 10) }
}

export function todayRange(): DateRange {
  const today = new Date().toISOString().slice(0, 10)
  return { from: today, to: today }
}

/** Height percentage relative to the max value in the series, floored so non-zero values stay visible. */
export function barHeights(values: number[], min = 4): number[] {
  const max = Math.max(...values, 0)
  if (max <= 0) return values.map(() => min)
  return values.map((v) => Math.max(min, Math.round((v / max) * 100)))
}
