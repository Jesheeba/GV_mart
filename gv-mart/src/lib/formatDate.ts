const IST_TIME_ZONE = "Asia/Kolkata"

/**
 * The single display format for dates across the app: DD/MM/YYYY, the
 * conventional reading for an Indian deployment. Before this, the same
 * "show a date" job was done ~47 different ways across the codebase —
 * raw ISO strings, DD/MM/YYYY with seconds, "23 Oct 2026", and bare
 * `.toLocaleDateString()` with no locale/timezone (renders in whatever the
 * visiting device is set to, which silently drifts a day for IST data near
 * midnight if the device isn't also on IST). Always anchored to
 * Asia/Kolkata so the date shown doesn't depend on the viewer's device.
 */
export function formatDate(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—"
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return "—"
  return date.toLocaleDateString("en-GB", { day: "2-digit", month: "2-digit", year: "numeric", timeZone: IST_TIME_ZONE })
}

/** Same DD/MM/YYYY date, plus a 12-hour IST time — "23/10/2026, 04:05 pm". */
export function formatDateTime(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—"
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return "—"
  const datePart = date.toLocaleDateString("en-GB", { day: "2-digit", month: "2-digit", year: "numeric", timeZone: IST_TIME_ZONE })
  const timePart = date.toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit", hour12: true, timeZone: IST_TIME_ZONE })
  return `${datePart}, ${timePart}`
}
