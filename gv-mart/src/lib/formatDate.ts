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

/** IST time only, lowercase am/pm — "4:54 pm", for chat-style timestamps. */
export function formatTime(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined || value === "") return ""
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return ""
  return date.toLocaleTimeString("en-IN", { hour: "numeric", minute: "2-digit", hour12: true, timeZone: IST_TIME_ZONE }).toLowerCase()
}

function istYear(date: Date): string {
  return date.toLocaleDateString("en-GB", { year: "numeric", timeZone: IST_TIME_ZONE })
}

/**
 * Compact IST date for lists — "6 Oct", or "6 Oct 2025" when it isn't the
 * current IST year. English month names, like the other helpers here.
 * Invoices/print keep the full DD/MM/YYYY formatDate.
 */
export function formatShortDate(value: string | number | Date | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—"
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return "—"
  const withYear = istYear(date) !== istYear(new Date())
  return date.toLocaleDateString("en-IN", { day: "numeric", month: "short", ...(withYear ? { year: "numeric" } : {}), timeZone: IST_TIME_ZONE })
}

/** Compact IST date-time for lists — "6 Oct, 10:00 am" (year only when not the current IST year). */
export function formatShortDateTime(value: string | number | Date | null | undefined): string {
  const datePart = formatShortDate(value)
  return datePart === "—" ? datePart : `${datePart}, ${formatTime(value)}`
}

/**
 * Compact IST start–end on one line: "6 Oct, 10:00 am – 11:30 am" on the same
 * IST day, otherwise both ends in full ("6 Oct, 10:00 pm – 7 Oct, 1:00 am").
 * A missing end shows "…" (still running); a missing start shows "—".
 */
export function formatShortDateTimeRange(
  start: string | number | Date | null | undefined,
  end: string | number | Date | null | undefined
): string {
  const startText = formatShortDateTime(start)
  if (startText === "—") return startText
  const endText = formatShortDateTime(end)
  if (endText === "—") return `${startText} – …`
  return formatShortDate(start) === formatShortDate(end) ? `${startText} – ${formatTime(end)}` : `${startText} – ${endText}`
}
