// Template variables that come from an AUTOMATION hand-off row (automation Phase 3 / Stage B), kept pure so vitest can cover
// them. The hand-off puts a small non-personal context into whatsapp_outbox.payload (days_left, eta_minutes, visit_date,
// expiry_date, language); the resolver turns that into the named variables the approved templates use.
import { formatIstDate } from "./wa-event-format.ts"

type Payload = Record<string, unknown> | null | undefined
export type Vars = Record<string, string | null | undefined>

function asInt(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN
  return Number.isFinite(n) && Number.isInteger(n) ? n : null
}

/** A date-only value (YYYY-MM-DD) is an IST calendar date; render it as "12 Oct 2026". */
export function formatIstCalendarDate(v: unknown): string | null {
  if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}/.test(v)) return null
  return formatIstDate(`${v.slice(0, 10)}T00:00:00+05:30`)
}

/** The language the automation engine already resolved (preferred_language, login language, rule language, English). */
export function automationPayloadLanguage(payload: Payload): "en" | "ta" | null {
  const l = payload?.language
  return l === "ta" ? "ta" : l === "en" ? "en" : null
}

/** True only for rows the automation hand-off wrote. */
export function isAutomationRow(payload: Payload): boolean {
  return typeof payload?.automation_queue_id === "string"
}

export function automationPayloadVars(payload: Payload): Vars {
  const vars: Vars = {}
  if (!payload) return vars
  const eta = asInt(payload.eta_minutes)
  if (eta != null && eta > 0) vars.eta = `${eta} ${eta === 1 ? "minute" : "minutes"}`
  const days = asInt(payload.days_left)
  if (days != null && days >= 0) {
    vars.days_left = String(days)
    vars.days = String(days)
  }
  const expiry = formatIstCalendarDate(payload.expiry_date)
  if (expiry) vars.expiry_date = expiry
  const visit = formatIstCalendarDate(payload.visit_date)
  if (visit) vars.visit_date = visit
  return vars
}

/** Variables for an AMC contract subject: the contract's own record first, the hand-off context second. */
export function amcContractVars(
  contract: { expiry_date: string | null; next_service_date?: string | null } | null,
  productName: string | null,
  planName: string | null,
  payload: Payload,
): Vars {
  const vars: Vars = {}
  if (productName) {
    vars.product = productName
    vars.product_name = productName
  }
  if (planName) {
    vars.plan = planName
    vars.plan_name = planName
  }
  const expiry = formatIstCalendarDate(contract?.expiry_date ?? null)
  if (expiry) vars.expiry_date = expiry
  const next = formatIstCalendarDate(contract?.next_service_date ?? null)
  if (next) vars.visit_date = next
  // the hand-off context wins (the visit date of THIS message, the window's days_left)
  return { ...vars, ...automationPayloadVars(payload) }
}
