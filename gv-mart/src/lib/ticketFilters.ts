import type { Enums } from "@/types/database"
import { isTicketOverdue } from "@/lib/ticketOverdue"

/**
 * Service page primary filters, in display order. The chips OVERLAP on
 * purpose: Overdue and Unassigned are subsets of Pending. One predicate per
 * filter feeds both the chip count and the list, so they cannot disagree.
 */
export const PRIMARY_FILTERS = ["overdue", "unassigned", "pending", "cancelled", "completed"] as const
export type PrimaryFilter = (typeof PRIMARY_FILTERS)[number]

export type FilterableTicket = {
  status: Enums<"ticket_status">
  sla_due_at: string | null
  product_id: string | null
  unlisted_product_name: string | null
  /** AMC visits (migration 20261020100000): only needed to tell "not yet due" visits apart; optional so other callers are unaffected. */
  contract_id?: string | null
  type?: Enums<"ticket_type"> | string | null
  appointments: { technician_id: string | null; scheduled_at?: string | null; status?: string }[]
}

/** settings.amc_assign_window_days default: an AMC visit is assigned a technician this many days before its date. */
export const DEFAULT_AMC_ASSIGN_WINDOW_DAYS = 7

const IST_OFFSET_MS = 5.5 * 3_600_000
function istDate(ms: number): string {
  return new Date(ms + IST_OFFSET_MS).toISOString().slice(0, 10)
}

/**
 * An AMC contract visit that is still months away: open, nobody assigned, scheduled after today + window (IST dates). It is
 * NOT waiting for a technician yet, so it is left out of the Pending and Unassigned counts and lists. Mirrors the SQL
 * public._ticket_is_future_amc_visit (which the KPI open-tickets tile uses); it appears again once it is inside the window.
 */
export function isFutureAmcVisit(r: FilterableTicket, now: number, windowDays: number = DEFAULT_AMC_ASSIGN_WINDOW_DAYS): boolean {
  if (!r.contract_id || r.type !== "amc" || r.status !== "open") return false
  if (r.appointments.some((a) => a.technician_id)) return false
  const dated = r.appointments.filter((a) => a.scheduled_at && (a.status === undefined || a.status === "scheduled"))
  if (dated.length === 0) return false
  const earliest = dated.map((a) => Date.parse(a.scheduled_at as string)).filter((t) => Number.isFinite(t)).sort((x, y) => x - y)[0]
  if (earliest === undefined) return false
  return istDate(earliest) > istDate(now + windowDays * 86_400_000)
}

// Pending = anything not finished: open + assigned + in_progress. A visit that is not yet due is not "pending work".
export function isPending(r: Pick<FilterableTicket, "status"> & Partial<FilterableTicket>, now?: number, windowDays?: number) {
  if (r.status === "completed" || r.status === "cancelled") return false
  if (now !== undefined && r.appointments && isFutureAmcVisit(r as FilterableTicket, now, windowDays)) return false
  return true
}

// Unassigned only means something for live tickets: a cancelled ticket with
// no technician is not work that is waiting for someone.
export function isUnassignedPending(r: FilterableTicket, now?: number, windowDays?: number) {
  return isPending(r, now, windowDays) && (r.appointments.length === 0 || r.appointments.every((a) => !a.technician_id))
}

export function isMissingProduct(r: Pick<FilterableTicket, "product_id" | "unlisted_product_name">) {
  return !r.product_id && !r.unlisted_product_name
}

export function matchesPrimaryFilter(r: FilterableTicket, filter: PrimaryFilter, now: number, windowDays: number = DEFAULT_AMC_ASSIGN_WINDOW_DAYS): boolean {
  switch (filter) {
    case "overdue":
      return isTicketOverdue(r, now)
    case "unassigned":
      return isUnassignedPending(r, now, windowDays)
    case "pending":
      return isPending(r, now, windowDays)
    case "cancelled":
      return r.status === "cancelled"
    case "completed":
      return r.status === "completed"
  }
}

export function countByPrimaryFilter(rows: FilterableTicket[], now: number, windowDays: number = DEFAULT_AMC_ASSIGN_WINDOW_DAYS): Record<PrimaryFilter, number> {
  const counts = { overdue: 0, unassigned: 0, pending: 0, cancelled: 0, completed: 0 }
  for (const f of PRIMARY_FILTERS) counts[f] = rows.filter((r) => matchesPrimaryFilter(r, f, now, windowDays)).length
  return counts
}

export function filterTickets<T extends FilterableTicket>(
  rows: T[],
  filter: PrimaryFilter,
  now: number,
  opts: { missingProductOnly?: boolean; windowDays?: number } = {}
): T[] {
  let out = rows.filter((r) => matchesPrimaryFilter(r, filter, now, opts.windowDays ?? DEFAULT_AMC_ASSIGN_WINDOW_DAYS))
  if (opts.missingProductOnly) out = out.filter(isMissingProduct)
  return out
}
