import { describe, expect, it } from "vitest"
import {
  PRIMARY_FILTERS,
  countByPrimaryFilter,
  filterTickets,
  isMissingProduct,
  type FilterableTicket,
} from "./ticketFilters"

const NOW = Date.parse("2026-10-10T10:00:00Z")
const PAST = "2026-10-10T08:00:00Z"
const FUTURE = "2026-10-10T14:00:00Z"
const TECH = [{ technician_id: "t1" }]

function t(over: Partial<FilterableTicket> & { id?: string }): FilterableTicket & { id: string } {
  return {
    id: "x",
    status: "open",
    sla_due_at: FUTURE,
    product_id: "p1",
    unlisted_product_name: null,
    appointments: TECH,
    ...over,
  }
}

// One ticket per interesting status/assignment/SLA combination.
const rows = [
  t({ id: "open-assigned-ok", status: "open" }),
  t({ id: "open-unassigned", status: "open", appointments: [] }),
  t({ id: "open-overdue", status: "open", sla_due_at: PAST }),
  t({ id: "assigned", status: "assigned" }),
  t({ id: "assigned-overdue-null-tech", status: "assigned", sla_due_at: PAST, appointments: [{ technician_id: null }] }),
  t({ id: "in-progress", status: "in_progress" }),
  t({ id: "in-progress-overdue", status: "in_progress", sla_due_at: PAST }),
  t({ id: "completed", status: "completed", sla_due_at: PAST }),
  t({ id: "completed-unassigned", status: "completed", appointments: [] }),
  t({ id: "cancelled", status: "cancelled" }),
  t({ id: "cancelled-unassigned", status: "cancelled", appointments: [], sla_due_at: PAST }),
  t({ id: "open-no-sla", status: "open", sla_due_at: null }),
]

const ids = (xs: { id: string }[]) => xs.map((x) => x.id).sort()

describe("service page primary filters", () => {
  it("is ordered Overdue, Unassigned, Pending, Cancelled, Completed", () => {
    expect([...PRIMARY_FILTERS]).toEqual(["overdue", "unassigned", "pending", "cancelled", "completed"])
  })

  it("pending = open + assigned + in_progress", () => {
    expect(ids(filterTickets(rows, "pending", NOW))).toEqual(
      ["assigned", "assigned-overdue-null-tech", "in-progress", "in-progress-overdue", "open-assigned-ok", "open-no-sla", "open-overdue", "open-unassigned"].sort()
    )
  })

  it("overdue = past SLA and still pending (completed/cancelled never overdue, no-SLA never overdue)", () => {
    expect(ids(filterTickets(rows, "overdue", NOW))).toEqual(["assigned-overdue-null-tech", "in-progress-overdue", "open-overdue"])
  })

  it("unassigned = pending with no technician on any appointment (cancelled/completed excluded)", () => {
    expect(ids(filterTickets(rows, "unassigned", NOW))).toEqual(["assigned-overdue-null-tech", "open-unassigned"])
  })

  it("cancelled and completed are exact status matches", () => {
    expect(ids(filterTickets(rows, "cancelled", NOW))).toEqual(["cancelled", "cancelled-unassigned"])
    expect(ids(filterTickets(rows, "completed", NOW))).toEqual(["completed", "completed-unassigned"])
  })

  it("overdue and unassigned are subsets of pending", () => {
    const pending = new Set(ids(filterTickets(rows, "pending", NOW)))
    for (const f of ["overdue", "unassigned"] as const) {
      for (const id of ids(filterTickets(rows, f, NOW))) expect(pending.has(id)).toBe(true)
    }
  })

  it("every chip count equals its list length", () => {
    const counts = countByPrimaryFilter(rows, NOW)
    for (const f of PRIMARY_FILTERS) expect(counts[f]).toBe(filterTickets(rows, f, NOW).length)
  })

  it("Missing product is a toggle that ANDs with the primary filter", () => {
    const withMissing = [
      ...rows,
      t({ id: "pending-missing", status: "open", product_id: null }),
      t({ id: "pending-unlisted", status: "open", product_id: null, unlisted_product_name: "Old RO" }),
      t({ id: "completed-missing", status: "completed", product_id: null }),
    ]
    expect(isMissingProduct(withMissing.find((r) => r.id === "pending-unlisted")!)).toBe(false)
    expect(ids(filterTickets(withMissing, "pending", NOW, { missingProductOnly: true }))).toEqual(["pending-missing"])
    expect(ids(filterTickets(withMissing, "completed", NOW, { missingProductOnly: true }))).toEqual(["completed-missing"])
  })
})
