import { describe, expect, it } from "vitest"
import {
  PRIMARY_FILTERS,
  computeRepeatComplaintKeys,
  countByPrimaryFilter,
  filterTickets,
  isFutureAmcVisit,
  isMissingProduct,
  isPending,
  matchesPrimaryFilter,
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
    // Unique per row by default (keyed on id) so unrelated tests don't
    // accidentally collide on the repeat-complaint customer+product key.
    customer_id: over.id ?? "x",
    created_at: "2026-10-01T00:00:00Z",
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
  it("is ordered Overdue, Unassigned, Pending, Cancelled, Completed, Repeat", () => {
    expect([...PRIMARY_FILTERS]).toEqual(["overdue", "unassigned", "pending", "cancelled", "completed", "repeat"])
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

  it("repeat = same customer+product appearing more than once within the lookback window (mirrors systemPages.ts#listRepeatComplaintTickets)", () => {
    const repeatRows = [
      t({ id: "r1", customer_id: "c1", product_id: "pA", created_at: "2026-09-01T00:00:00Z" }),
      t({ id: "r2", customer_id: "c1", product_id: "pA", created_at: "2026-09-15T00:00:00Z" }),
      // Same customer, different product — not a repeat for that product.
      t({ id: "r3", customer_id: "c1", product_id: "pB", created_at: "2026-09-15T00:00:00Z" }),
      // Different customer, same product — not a repeat either.
      t({ id: "r4", customer_id: "c2", product_id: "pA", created_at: "2026-09-15T00:00:00Z" }),
      // Same customer+product, but outside the 90-day lookback from NOW (2026-10-10).
      t({ id: "r5", customer_id: "c3", product_id: "pC", created_at: "2026-01-01T00:00:00Z" }),
      t({ id: "r6", customer_id: "c3", product_id: "pC", created_at: "2026-01-02T00:00:00Z" }),
      // No product — never counts as a repeat, even if it duplicates a customer.
      t({ id: "r7", customer_id: "c1", product_id: null, created_at: "2026-09-15T00:00:00Z" }),
    ]
    expect(ids(filterTickets(repeatRows, "repeat", NOW))).toEqual(["r1", "r2"])
    expect(computeRepeatComplaintKeys(repeatRows, NOW)).toEqual(new Set(["c1:pA"]))
    const counts = countByPrimaryFilter(repeatRows, NOW)
    expect(counts.repeat).toBe(2)
  })

  it("the repeat lookback window is a parameter", () => {
    const repeatRows = [
      t({ id: "old1", customer_id: "c9", product_id: "pZ", created_at: "2026-01-01T00:00:00Z" }),
      t({ id: "old2", customer_id: "c9", product_id: "pZ", created_at: "2026-01-02T00:00:00Z" }),
    ]
    expect(ids(filterTickets(repeatRows, "repeat", NOW))).toEqual([])
    expect(ids(filterTickets(repeatRows, "repeat", NOW, { lookbackDays: 365 }))).toEqual(["old1", "old2"])
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

describe("AMC visits that are not yet due (migration 20261022100000)", () => {
  // 13 Oct 2026, 10:00 IST
  const NOW = Date.parse("2026-10-13T04:30:00Z")
  const base = {
    status: "open" as const,
    sla_due_at: null,
    product_id: "p",
    unlisted_product_name: null,
    customer_id: "cust-amc",
    created_at: "2026-10-01T00:00:00Z",
    contract_id: "c1",
    type: "amc",
  }
  const far = { ...base, appointments: [{ technician_id: null, scheduled_at: "2027-04-13T03:45:00Z", status: "scheduled" }] }
  const near = { ...base, appointments: [{ technician_id: null, scheduled_at: "2026-10-18T03:45:00Z", status: "scheduled" }] }
  const edge = { ...base, appointments: [{ technician_id: null, scheduled_at: "2026-10-20T03:45:00Z", status: "scheduled" }] } // today + 7
  const justPast = { ...base, appointments: [{ technician_id: null, scheduled_at: "2026-10-21T03:45:00Z", status: "scheduled" }] } // today + 8

  it("a visit months away is not pending and not unassigned", () => {
    expect(isFutureAmcVisit(far, NOW)).toBe(true)
    expect(matchesPrimaryFilter(far, "unassigned", NOW)).toBe(false)
    expect(matchesPrimaryFilter(far, "pending", NOW)).toBe(false)
  })

  it("inside the window (today + 7 included) it counts again", () => {
    expect(isFutureAmcVisit(near, NOW)).toBe(false)
    expect(matchesPrimaryFilter(near, "unassigned", NOW)).toBe(true)
    expect(isFutureAmcVisit(edge, NOW)).toBe(false)
    expect(isFutureAmcVisit(justPast, NOW)).toBe(true)
  })

  it("the window is a parameter", () => {
    expect(isFutureAmcVisit(justPast, NOW, 30)).toBe(false)
    expect(matchesPrimaryFilter(justPast, "unassigned", NOW, 30)).toBe(true)
  })

  it("assigned, non-AMC, non-open and contract-less tickets are never 'not yet due'", () => {
    expect(isFutureAmcVisit({ ...far, appointments: [{ technician_id: "t1", scheduled_at: "2027-04-13T03:45:00Z", status: "scheduled" }] }, NOW)).toBe(false)
    expect(isFutureAmcVisit({ ...far, type: "paid" }, NOW)).toBe(false)
    expect(isFutureAmcVisit({ ...far, contract_id: null }, NOW)).toBe(false)
    expect(isFutureAmcVisit({ ...far, status: "assigned" as const }, NOW)).toBe(false)
    expect(isFutureAmcVisit({ ...far, appointments: [] }, NOW)).toBe(false)
  })

  it("chip counts and lists agree and the far visit disappears from both", () => {
    const rows = [far, near]
    const counts = countByPrimaryFilter(rows, NOW)
    expect(counts.unassigned).toBe(1)
    expect(counts.pending).toBe(1)
    expect(filterTickets(rows, "unassigned", NOW)).toEqual([near])
  })

  it("old callers (no 'now') behave exactly as before", () => {
    expect(isPending({ status: "open" })).toBe(true)
    expect(isPending({ status: "completed" })).toBe(false)
  })
})
