import { describe, expect, it } from "vitest"
import { countDueOrOverdueParts, filterDueOrOverdueParts, type CustomerPartSchedule } from "./useDueParts"

/**
 * Product Lifecycle & Automated Service Reminder System — pins the pure
 * filter/count logic that drives the "N parts due" chip (TechnicianHomePage,
 * JobDetailPage) and the on-site warning list (SpareSelectStep), the same
 * way the rest of this codebase tests rendering-adjacent logic as plain
 * functions rather than mounting components (no .test.tsx files exist in
 * this repo — see e.g. src/services/technician.test.ts).
 */
function row(overrides: Partial<CustomerPartSchedule>): CustomerPartSchedule {
  return {
    id: "sched-1",
    installedProductId: "prod-1",
    label: "RO Membrane",
    intervalValue: 6,
    intervalUnit: "months",
    lastReplacedDate: null,
    nextDueDate: "2026-11-01",
    status: "pending",
    ...overrides,
  }
}

describe("filterDueOrOverdueParts", () => {
  it("returns an empty array for undefined input", () => {
    expect(filterDueOrOverdueParts(undefined)).toEqual([])
  })

  it("keeps due_soon, due, and overdue rows", () => {
    const rows = [row({ id: "a", status: "due_soon" }), row({ id: "b", status: "due" }), row({ id: "c", status: "overdue" })]
    expect(filterDueOrOverdueParts(rows).map((r) => r.id)).toEqual(["a", "b", "c"])
  })

  it("excludes pending and replaced_na rows", () => {
    const rows = [row({ id: "a", status: "pending" }), row({ id: "b", status: "replaced_na" }), row({ id: "c", status: "overdue" })]
    expect(filterDueOrOverdueParts(rows).map((r) => r.id)).toEqual(["c"])
  })

  it("preserves row order and shape (no mutation)", () => {
    const rows = [row({ id: "a", status: "overdue", label: "Carbon Filter" })]
    const result = filterDueOrOverdueParts(rows)
    expect(result).not.toBe(rows)
    expect(result[0]).toEqual(rows[0])
  })
})

describe("countDueOrOverdueParts", () => {
  it("is 0 for undefined input", () => {
    expect(countDueOrOverdueParts(undefined)).toBe(0)
  })

  it("is 0 when no row needs attention — the chip must not render", () => {
    const rows = [row({ status: "pending" }), row({ status: "replaced_na" })]
    expect(countDueOrOverdueParts(rows)).toBe(0)
  })

  it("counts only due_soon/due/overdue rows, mixed with others", () => {
    const rows = [
      row({ id: "a", status: "pending" }),
      row({ id: "b", status: "due_soon" }),
      row({ id: "c", status: "due" }),
      row({ id: "d", status: "overdue" }),
      row({ id: "e", status: "replaced_na" }),
    ]
    expect(countDueOrOverdueParts(rows)).toBe(3)
  })
})
