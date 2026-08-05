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
