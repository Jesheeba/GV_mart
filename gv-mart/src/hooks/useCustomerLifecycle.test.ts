import { describe, expect, it } from "vitest"
import {
  getLifetimeExpiryForProduct,
  groupDuePartsByProductId,
  isLifetimeExpiryNear,
  pickSoonestDuePart,
  type CustomerInstalledProduct,
  type CustomerPartSchedule,
} from "./useCustomerLifecycle"

/**
 * Product Lifecycle & Automated Service Reminder System — Drop 2, W3
 * (customer-facing). Pins the pure logic behind CustomerHomePage's lifecycle
 * banner and the owned-product cards' due-badge/lifetime-expiry rendering,
 * the same way useDueParts.test.ts pins the technician-side equivalents —
 * no .test.tsx files exist in this repo (see useDueParts.test.ts's own note).
 */
function part(overrides: Partial<CustomerPartSchedule>): CustomerPartSchedule {
  return {
    id: "sched-1",
    installedProductId: "inst-1",
    label: "RO Membrane",
    intervalValue: 6,
    intervalUnit: "months",
    lastReplacedDate: null,
    nextDueDate: "2026-11-01",
    status: "pending",
    ...overrides,
  }
}

function installed(overrides: Partial<CustomerInstalledProduct>): CustomerInstalledProduct {
  return {
    id: "inst-1",
    productId: "prod-1",
    installationDate: "2025-01-01",
    lifetimeExpiryDate: null,
    status: "active",
    ...overrides,
  }
}

describe("pickSoonestDuePart", () => {
  it("returns null for undefined/empty input", () => {
    expect(pickSoonestDuePart(undefined)).toBeNull()
    expect(pickSoonestDuePart([])).toBeNull()
  })

  it("ignores pending and replaced_na rows", () => {
    const rows = [part({ id: "a", status: "pending" }), part({ id: "b", status: "replaced_na" })]
    expect(pickSoonestDuePart(rows)).toBeNull()
  })

  it("picks the row with the earliest nextDueDate among due_soon/due/overdue", () => {
    const rows = [
      part({ id: "a", status: "due_soon", nextDueDate: "2026-12-01" }),
      part({ id: "b", status: "overdue", nextDueDate: "2026-10-01" }),
      part({ id: "c", status: "due", nextDueDate: "2026-11-15" }),
    ]
    expect(pickSoonestDuePart(rows)?.id).toBe("b")
  })
})

describe("isLifetimeExpiryNear", () => {
  it("is false for a null/undefined expiry date", () => {
    expect(isLifetimeExpiryNear(null, "2026-10-30")).toBe(false)
    expect(isLifetimeExpiryNear(undefined, "2026-10-30")).toBe(false)
  })

  it("is true when the expiry date is already past", () => {
    expect(isLifetimeExpiryNear("2026-09-01", "2026-10-30")).toBe(true)
  })

  it("is true when within the default 90-day window", () => {
    expect(isLifetimeExpiryNear("2027-01-20", "2026-10-30")).toBe(true)
  })

  it("is false when further out than the window", () => {
    expect(isLifetimeExpiryNear("2027-06-01", "2026-10-30")).toBe(false)
  })

  it("respects a custom window", () => {
    expect(isLifetimeExpiryNear("2026-11-15", "2026-10-30", 10)).toBe(false)
    expect(isLifetimeExpiryNear("2026-11-05", "2026-10-30", 10)).toBe(true)
  })
})

describe("groupDuePartsByProductId", () => {
  it("returns an empty map for undefined input", () => {
    expect(groupDuePartsByProductId(undefined, undefined).size).toBe(0)
  })

  it("maps a due-part row to its catalog product via the installed-product link", () => {
    const installedProducts = [installed({ id: "inst-1", productId: "prod-1" }), installed({ id: "inst-2", productId: "prod-2" })]
    const dueParts = [part({ id: "a", installedProductId: "inst-1", status: "due" }), part({ id: "b", installedProductId: "inst-2", status: "overdue" })]
    const grouped = groupDuePartsByProductId(dueParts, installedProducts)
    expect(grouped.get("prod-1")?.map((r) => r.id)).toEqual(["a"])
    expect(grouped.get("prod-2")?.map((r) => r.id)).toEqual(["b"])
  })

  it("excludes pending/replaced_na rows and rows with no matching installed product", () => {
    const installedProducts = [installed({ id: "inst-1", productId: "prod-1" })]
    const dueParts = [
      part({ id: "a", installedProductId: "inst-1", status: "pending" }),
      part({ id: "b", installedProductId: "inst-1", status: "replaced_na" }),
      part({ id: "c", installedProductId: "unknown-inst", status: "due" }),
    ]
    expect(groupDuePartsByProductId(dueParts, installedProducts).size).toBe(0)
  })

  it("groups multiple due rows under the same product id", () => {
    const installedProducts = [installed({ id: "inst-1", productId: "prod-1" })]
    const dueParts = [part({ id: "a", installedProductId: "inst-1", status: "due" }), part({ id: "b", installedProductId: "inst-1", status: "overdue" })]
    expect(groupDuePartsByProductId(dueParts, installedProducts).get("prod-1")?.map((r) => r.id)).toEqual(["a", "b"])
  })
})

describe("getLifetimeExpiryForProduct", () => {
  it("returns null when no installed products match the product id", () => {
    expect(getLifetimeExpiryForProduct([installed({ productId: "other" })], "prod-1")).toBeNull()
  })

  it("ignores removed/expired installed units", () => {
    const installedProducts = [installed({ productId: "prod-1", status: "removed", lifetimeExpiryDate: "2026-11-01" })]
    expect(getLifetimeExpiryForProduct(installedProducts, "prod-1")).toBeNull()
  })

  it("picks the soonest expiry among multiple active units of the same product", () => {
    const installedProducts = [
      installed({ id: "inst-1", productId: "prod-1", status: "active", lifetimeExpiryDate: "2027-01-01" }),
      installed({ id: "inst-2", productId: "prod-1", status: "active", lifetimeExpiryDate: "2026-11-15" }),
    ]
    expect(getLifetimeExpiryForProduct(installedProducts, "prod-1")).toBe("2026-11-15")
  })
})
