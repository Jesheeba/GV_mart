const IST_TIME_ZONE = "Asia/Kolkata"

/**
 * "Now" in Asia/Kolkata, as a date ("YYYY-MM-DD") and 24h time ("HH:MM"),
 * independent of the device's own timezone/locale. Naive local reads of
 * "today"/"now" (e.g. `new Date().toISOString().slice(0, 10)`, which is
 * UTC) have bitten this app before — see
 * 20260731100000_fix_scheduled_at_timezone.sql — so any date/time picker
 * that needs to know "is this today" or "has this already passed" should
 * go through here rather than reading the device clock directly.
 */
export function getIstNow(): { date: string; time: string } {
  const now = new Date()
  return {
    date: now.toLocaleDateString("en-CA", { timeZone: IST_TIME_ZONE }),
    time: now.toLocaleTimeString("en-GB", { timeZone: IST_TIME_ZONE, hour: "2-digit", minute: "2-digit", hour12: false }),
  }
}

/**
 * Absolute instants for the start/end of an IST calendar day ("YYYY-MM-DD").
 * IST has no DST, so the fixed +05:30 offset is exact — and, unlike
 * `new Date(`${d}T00:00:00`)` (device timezone) or a bare `${d}T00:00:00`
 * string (read by Postgres as UTC), it does not depend on the device or the
 * database session timezone.
 */
export function istDayStartIso(date: string): string {
  return new Date(`${date}T00:00:00+05:30`).toISOString()
}
export function istDayEndIso(date: string): string {
  return new Date(`${date}T23:59:59.999+05:30`).toISOString()
}
/** IST calendar date ("YYYY-MM-DD") of a timestamp. */
export function istDateOf(timestamp: string | Date): string {
  return new Date(timestamp).toLocaleDateString("en-CA", { timeZone: IST_TIME_ZONE })
}
