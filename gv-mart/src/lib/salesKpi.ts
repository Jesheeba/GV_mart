import { getIstNow } from "@/lib/ist"

/** "YYYY-MM" of the current month in Indian time (never the device clock). */
export function currentIstMonth(now?: { date: string }): string {
  return (now ?? getIstNow()).date.slice(0, 7)
}

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/

export function isMonthString(v: string): boolean {
  return MONTH_RE.test(v)
}

/** First and last calendar day ("YYYY-MM-DD") of a "YYYY-MM" month. Throws on a malformed month. */
export function monthRange(ym: string): { from: string; to: string } {
  if (!isMonthString(ym)) throw new Error(`monthRange: expected YYYY-MM, got "${ym}"`)
  const [y, m] = ym.split("-").map(Number)
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate()
  return { from: `${ym}-01`, to: `${ym}-${String(last).padStart(2, "0")}` }
}

/** The calendar day before a "YYYY-MM-DD" date (pure date arithmetic, no timezone involved). */
export function previousDay(date: string): string {
  const [y, m, d] = date.split("-").map(Number)
  return new Date(Date.UTC(y, m - 1, d - 1)).toISOString().slice(0, 10)
}

/** Average ticket size: total / invoices, null (shown as "-") when there are no invoices. */
export function averageTicket(total: number, count: number): number | null {
  return count > 0 ? Math.round((total / count) * 100) / 100 : null
}
