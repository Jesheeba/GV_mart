/**
 * Local-calendar date formatting. Do NOT use `date.toISOString().slice(0, 10)`
 * for dates built from local-midnight `Date`s (e.g. `new Date(y, m, 1)`): in a
 * UTC+ zone such as IST, toISOString() converts to UTC and lands on the
 * previous calendar day, so month boundaries shift back a day.
 */
export function toLocalDateString(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
}

/** Local "YYYY-MM" of a date. */
export function toLocalMonthString(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`
}
