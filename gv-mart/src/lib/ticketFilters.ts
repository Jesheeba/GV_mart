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
  appointments: { technician_id: string | null }[]
}

// Pending = anything not finished: open + assigned + in_progress.
export function isPending(r: Pick<FilterableTicket, "status">) {
  return r.status !== "completed" && r.status !== "cancelled"
}

// Unassigned only means something for live tickets: a cancelled ticket with
// no technician is not work that is waiting for someone.
export function isUnassignedPending(r: FilterableTicket) {
  return isPending(r) && (r.appointments.length === 0 || r.appointments.every((a) => !a.technician_id))
}

export function isMissingProduct(r: Pick<FilterableTicket, "product_id" | "unlisted_product_name">) {
  return !r.product_id && !r.unlisted_product_name
}

export function matchesPrimaryFilter(r: FilterableTicket, filter: PrimaryFilter, now: number): boolean {
  switch (filter) {
    case "overdue":
      return isTicketOverdue(r, now)
    case "unassigned":
      return isUnassignedPending(r)
    case "pending":
      return isPending(r)
    case "cancelled":
      return r.status === "cancelled"
    case "completed":
      return r.status === "completed"
  }
}

export function countByPrimaryFilter(rows: FilterableTicket[], now: number): Record<PrimaryFilter, number> {
  const counts = { overdue: 0, unassigned: 0, pending: 0, cancelled: 0, completed: 0 }
  for (const f of PRIMARY_FILTERS) counts[f] = rows.filter((r) => matchesPrimaryFilter(r, f, now)).length
  return counts
}

export function filterTickets<T extends FilterableTicket>(
  rows: T[],
  filter: PrimaryFilter,
  now: number,
  opts: { missingProductOnly?: boolean } = {}
): T[] {
  let out = rows.filter((r) => matchesPrimaryFilter(r, filter, now))
  if (opts.missingProductOnly) out = out.filter(isMissingProduct)
  return out
}
