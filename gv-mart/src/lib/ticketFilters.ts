import type { Enums } from "@/types/database"
import { isTicketOverdue } from "@/lib/ticketOverdue"

/**
 * Service page primary filters, in display order. The chips OVERLAP on
 * purpose: Overdue and Unassigned are subsets of Pending. One predicate per
 * filter feeds both the chip count and the list, so they cannot disagree.
 *
 * "repeat" (cleanup batch 1 item 4) ports /admin/complaints's Repeat
 * Complaint tab in here as a filter chip — same predicate
 * (listRepeatComplaintTickets in systemPages.ts): the same customer_id +
 * product_id appearing more than once within a trailing window. Unlike the
 * other filters it needs the whole ticket set to count duplicates, so it is
 * threaded through separately (see computeRepeatComplaintKeys) rather than
 * being a pure per-row predicate like the rest.
 */
export const PRIMARY_FILTERS = ["overdue", "unassigned", "pending", "cancelled", "completed", "repeat"] as const
export type PrimaryFilter = (typeof PRIMARY_FILTERS)[number]

export type FilterableTicket = {
  status: Enums<"ticket_status">
  sla_due_at: string | null
  product_id: string | null
  unlisted_product_name: string | null
  customer_id: string
  created_at: string
  /** AMC visits (migration 20261022100000): only needed to tell "not yet due" visits apart; optional so other callers are unaffected. */
  contract_id?: string | null
  type?: Enums<"ticket_type"> | string | null
  appointments: { technician_id: string | null; scheduled_at?: string | null; status?: string }[]
}

/** Same customer_id + product_id appearing more than once within a trailing window = repeat complaint (mirrors systemPages.ts#listRepeatComplaintTickets). */
export const DEFAULT_REPEAT_COMPLAINT_LOOKBACK_DAYS = 90

export function computeRepeatComplaintKeys(rows: FilterableTicket[], now: number, lookbackDays: number = DEFAULT_REPEAT_COMPLAINT_LOOKBACK_DAYS): Set<string> {
  const sinceMs = now - lookbackDays * 86_400_000
  const counts = new Map<string, number>()
  for (const r of rows) {
    if (!r.product_id) continue
    if (Date.parse(r.created_at) < sinceMs) continue
    const key = `${r.customer_id}:${r.product_id}`
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  const repeatKeys = new Set<string>()
  for (const [key, count] of counts) {
    if (count > 1) repeatKeys.add(key)
  }
  return repeatKeys
}

function isRepeatComplaint(r: FilterableTicket, repeatKeys: Set<string> | undefined): boolean {
  if (!repeatKeys || !r.product_id) return false
  return repeatKeys.has(`${r.customer_id}:${r.product_id}`)
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

export function matchesPrimaryFilter(
  r: FilterableTicket,
  filter: PrimaryFilter,
  now: number,
  windowDays: number = DEFAULT_AMC_ASSIGN_WINDOW_DAYS,
  repeatKeys?: Set<string>
): boolean {
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
    case "repeat":
      return isRepeatComplaint(r, repeatKeys)
  }
}

export function countByPrimaryFilter(
  rows: FilterableTicket[],
  now: number,
  windowDays: number = DEFAULT_AMC_ASSIGN_WINDOW_DAYS,
  lookbackDays: number = DEFAULT_REPEAT_COMPLAINT_LOOKBACK_DAYS
): Record<PrimaryFilter, number> {
  const repeatKeys = computeRepeatComplaintKeys(rows, now, lookbackDays)
  const counts = { overdue: 0, unassigned: 0, pending: 0, cancelled: 0, completed: 0, repeat: 0 }
  for (const f of PRIMARY_FILTERS) counts[f] = rows.filter((r) => matchesPrimaryFilter(r, f, now, windowDays, repeatKeys)).length
  return counts
}

export function filterTickets<T extends FilterableTicket>(
  rows: T[],
  filter: PrimaryFilter,
  now: number,
  opts: { missingProductOnly?: boolean; windowDays?: number; lookbackDays?: number } = {}
): T[] {
  const repeatKeys = filter === "repeat" ? computeRepeatComplaintKeys(rows, now, opts.lookbackDays ?? DEFAULT_REPEAT_COMPLAINT_LOOKBACK_DAYS) : undefined
  let out = rows.filter((r) => matchesPrimaryFilter(r, filter, now, opts.windowDays ?? DEFAULT_AMC_ASSIGN_WINDOW_DAYS, repeatKeys))
  if (opts.missingProductOnly) out = out.filter(isMissingProduct)
  return out
}
