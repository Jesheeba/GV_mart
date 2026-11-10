import { describe, expect, it } from "vitest"
import { billBreakdown, findStockGap, formatCurrency, round2 } from "./sale-calc"

describe("round2", () => {
  it("rounds up at the .005 boundary (Number.EPSILON nudge)", () => {
    expect(round2(1.005)).toBe(1.01)
  })
  it("rounds a normal fractional value", () => {
    expect(round2(2.675)).toBe(2.68)
  })
  it("leaves an already-2dp value unchanged", () => {
    expect(round2(10.1)).toBe(10.1)
  })
  it("rounds 0 to 0", () => {
    expect(round2(0)).toBe(0)
  })
})

describe("billBreakdown", () => {
  it("computes discount, gst and total for a typical sale", () => {
    // 1000 subtotal, 10% discount -> 900 base, 18% gst -> 162, total 1062
    expect(billBreakdown(1000, 10, 18)).toEqual({ subtotal: 1000, discount: 100, gst: 162, total: 1062 })
  })

  it("handles a zero subtotal", () => {
    expect(billBreakdown(0, 10, 18)).toEqual({ subtotal: 0, discount: 0, gst: 0, total: 0 })
  })

  it("handles a zero discount", () => {
    expect(billBreakdown(500, 0, 18)).toEqual({ subtotal: 500, discount: 0, gst: 90, total: 590 })
  })

  it("handles a 100% discount (fully waived)", () => {
    expect(billBreakdown(500, 100, 18)).toEqual({ subtotal: 500, discount: 500, gst: 0, total: 0 })
  })

  it("rounds each leg independently, matching the server RPC's arithmetic", () => {
    expect(billBreakdown(999.995, 0, 18)).toEqual({ subtotal: 1000, discount: 0, gst: 180, total: 1179.99 })
  })
})

describe("formatCurrency", () => {
  it("formats a round number with Indian digit grouping and 2 decimals", () => {
    expect(formatCurrency(1000)).toBe("₹1,000.00")
  })
  it("formats 0", () => {
    expect(formatCurrency(0)).toBe("₹0.00")
  })
  it("formats a large value with lakh-style grouping", () => {
    expect(formatCurrency(1234567.5)).toBe("₹12,34,567.50")
  })
  it("always shows exactly 2 decimal places", () => {
    expect(formatCurrency(99.999)).toBe("₹100.00")
  })
})

describe("findStockGap", () => {
  const stock = [{ item_id: "p1", stock_qty: 3 }]

  it("returns null when every line has enough stock", () => {
    expect(findStockGap([{ itemId: "p1", name: "Widget", qty: 2 }], stock)).toBeNull()
  })

  it("flags no_record when the product has no inventory row at all (distinct from zero stock)", () => {
    expect(findStockGap([{ itemId: "p2", name: "Gadget", qty: 1 }], stock)).toEqual({ kind: "no_record", name: "Gadget" })
  })

  it("flags insufficient when a row exists but qty requested exceeds stock_qty", () => {
    expect(findStockGap([{ itemId: "p1", name: "Widget", qty: 5 }], stock)).toEqual({ kind: "insufficient", name: "Widget", available: 3 })
  })

  it("treats an inventory row with stock_qty=0 as insufficient, not no_record", () => {
    expect(findStockGap([{ itemId: "z", name: "Zero Stock Item", qty: 1 }], [{ item_id: "z", stock_qty: 0 }])).toEqual({
      kind: "insufficient",
      name: "Zero Stock Item",
      available: 0,
    })
  })

  it("checks lines in order and returns the first gap found", () => {
    expect(
      findStockGap(
        [
          { itemId: "p1", name: "Widget", qty: 1 },
          { itemId: "missing", name: "No Row Item", qty: 1 },
        ],
        stock
      )
    ).toEqual({ kind: "no_record", name: "No Row Item" })
  })

  it("treats an empty line list as no gap", () => {
    expect(findStockGap([], stock)).toBeNull()
  })

  it("treats undefined stock data (not yet loaded) as no record for any line", () => {
    expect(findStockGap([{ itemId: "p1", name: "Widget", qty: 1 }], undefined)).toEqual({ kind: "no_record", name: "Widget" })
  })
})
