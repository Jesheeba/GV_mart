// Pure formatting helpers for template variables (no Deno / Supabase imports so vitest can use them).

/** Short, human-quotable reference for a uuid: first 8 hex chars, upper case. */
export function shortRef(id: string | null | undefined): string {
  return (id ?? "").replace(/-/g, "").slice(0, 8).toUpperCase()
}

const IST_OFFSET_MS = 5.5 * 3_600_000
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/** "12 Oct, 3:30 PM" in IST, independent of the machine's timezone. */
export function formatIstSlot(iso: string | null | undefined): string | null {
  if (!iso) return null
  const t = Date.parse(iso)
  if (!Number.isFinite(t)) return null
  const d = new Date(t + IST_OFFSET_MS)
  const hours24 = d.getUTCHours()
  const hour12 = hours24 % 12 === 0 ? 12 : hours24 % 12
  const minutes = String(d.getUTCMinutes()).padStart(2, "0")
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}, ${hour12}:${minutes} ${hours24 < 12 ? "AM" : "PM"}`
}

/** "12 Oct 2026" in IST. */
export function formatIstDate(iso: string | null | undefined): string | null {
  if (!iso) return null
  const t = Date.parse(iso)
  if (!Number.isFinite(t)) return null
  const d = new Date(t + IST_OFFSET_MS)
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

/** "Rs 1,234" / "Rs 1,234.50" (Indian digit grouping), no currency symbol that a template body may mishandle. */
export function formatRupees(amount: number | string | null | undefined): string | null {
  if (amount == null || amount === "") return null
  const n = typeof amount === "number" ? amount : Number(amount)
  if (!Number.isFinite(n)) return null
  const fixed = Math.abs(n) % 1 === 0 ? String(Math.trunc(Math.abs(n))) : Math.abs(n).toFixed(2)
  const [whole, frac] = fixed.split(".")
  const last3 = whole.slice(-3)
  const rest = whole.slice(0, -3)
  const grouped = rest ? rest.replace(/\B(?=(\d{2})+(?!\d))/g, ",") + "," + last3 : last3
  return `Rs ${n < 0 ? "-" : ""}${grouped}${frac ? "." + frac : ""}`
}
