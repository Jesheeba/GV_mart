import { describe, expect, it } from "vitest"
import { billBreakdown } from "./sale-calc"
import { OUTBOX_REQUIRED_FIELDS } from "./offline/outboxContract"

// gst-everywhere (20261230100000). Same numbers as supabase/tests/gst_everywhere.test.sql,
// so the screen total and the server invoice agree to the paisa.

describe("gst-everywhere E1: technician on-site invoice total includes GST", () => {
  it("Extra (org default): 1000 -> GST 180, total 1180 (was shown as 1000 before the fix)", () => {
    expect(billBreakdown(1000, 0, 18, false)).toEqual({ subtotal: 1000, discount: 0, gst: 180, total: 1180 })
  })
  it("Included: 1000 -> GST 152.54 inside, total stays 1000", () => {
    expect(billBreakdown(1000, 0, 18, true)).toEqual({ subtotal: 1000, discount: 0, gst: 152.54, total: 1000 })
  })
  it("discount is taken before GST: 10% of 1000 Extra -> GST 162, total 1062", () => {
    expect(billBreakdown(1000, 10, 18, false)).toEqual({ subtotal: 1000, discount: 100, gst: 162, total: 1062 })
  })
  it("rate 0: no GST either way", () => {
    expect(billBreakdown(1000, 0, 0, false).total).toBe(1000)
    expect(billBreakdown(1000, 0, 0, true).gst).toBe(0)
  })
})

describe("gst-everywhere E2/E3: AMC (technician, admin, customer renewal)", () => {
  it("plan 2000 Extra -> 2360", () => {
    expect(billBreakdown(2000, 0, 18, false)).toMatchObject({ gst: 360, total: 2360 })
  })
  it("plan 2000 Included -> GST 305.08, total 2000", () => {
    expect(billBreakdown(2000, 0, 18, true)).toMatchObject({ gst: 305.08, total: 2000 })
  })
  it("2 years x 2000 Included -> GST 610.17, total 4000", () => {
    expect(billBreakdown(4000, 0, 18, true)).toMatchObject({ gst: 610.17, total: 4000 })
  })
})

describe("gst-everywhere E4: rental monthly bill", () => {
  it("monthly 1000: Extra 1180, Included 1000", () => {
    expect(billBreakdown(1000, 0, 18, false).total).toBe(1180)
    expect(billBreakdown(1000, 0, 18, true).total).toBe(1000)
  })
})

describe("gst-everywhere E5: offline jobs already queued on phones keep syncing", () => {
  it("gstInclusive is NOT a required outbox field (older jobs have no such key; the server falls back to the org default)", () => {
    expect(OUTBOX_REQUIRED_FIELDS["service_invoice.create"]).not.toContain("gstInclusive")
    expect(OUTBOX_REQUIRED_FIELDS["amc.sell_onsite"]).not.toContain("gstInclusive")
  })
})
