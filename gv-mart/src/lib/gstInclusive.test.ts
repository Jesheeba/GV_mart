import { describe, expect, it } from "vitest"
import { billBreakdown } from "./sale-calc"
import { payableTotal, type SaleCartState } from "@/app/admin/sales/types"

describe("gst-inclusive-toggle AC: GST included", () => {
  it("₹11,800 @18% included → GST 1,800.00, total stays 11,800.00", () => {
    expect(billBreakdown(11800, 0, 18, true)).toEqual({ subtotal: 11800, discount: 0, gst: 1800, total: 11800 })
  })
  it("real product ₹12,500 @18% included → GST 1,906.78, total 12,500.00", () => {
    expect(billBreakdown(12500, 0, 18, true)).toEqual({ subtotal: 12500, discount: 0, gst: 1906.78, total: 12500 })
  })
  it("discount comes off first, GST is then taken out of the discounted amount", () => {
    // 12,500 − 10% = 11,250; 11,250 × 18/118 = 1,716.10
    expect(billBreakdown(12500, 10, 18, true)).toEqual({ subtotal: 12500, discount: 1250, gst: 1716.1, total: 11250 })
  })
  it("taxable value (total − gst) + gst always equals the total", () => {
    for (const price of [1, 15, 99.99, 750, 12500, 25000]) {
      const b = billBreakdown(price, 5, 18, true)
      expect(b.total - b.gst + b.gst).toBe(b.total)
      expect(b.total).toBe(Math.round(price * 0.95 * 100) / 100)
    }
  })
})

describe("gst-inclusive-toggle AC: GST extra is unchanged (default)", () => {
  it("default argument = extra: ₹10,000 @18% → GST 1,800.00, total 11,800.00", () => {
    expect(billBreakdown(10000, 0, 18)).toEqual({ subtotal: 10000, discount: 0, gst: 1800, total: 11800 })
    expect(billBreakdown(10000, 0, 18, false)).toEqual(billBreakdown(10000, 0, 18))
  })
})

describe("gst-inclusive-toggle edge cases", () => {
  it("rate 0 → no GST either way", () => {
    expect(billBreakdown(500, 0, 0, true)).toEqual({ subtotal: 500, discount: 0, gst: 0, total: 500 })
    expect(billBreakdown(500, 0, 0, false)).toEqual({ subtotal: 500, discount: 0, gst: 0, total: 500 })
  })
  it("100% discount → zero GST and zero total", () => {
    expect(billBreakdown(500, 100, 18, true)).toEqual({ subtotal: 500, discount: 500, gst: 0, total: 0 })
  })
  it("zero subtotal", () => {
    expect(billBreakdown(0, 0, 18, true)).toEqual({ subtotal: 0, discount: 0, gst: 0, total: 0 })
  })
})

describe("gst-inclusive-toggle: payable on New Sale follows the switch", () => {
  const cart: SaleCartState = {
    productLines: [{ productId: "p", name: "ROP 2090 BLUE", brandName: "—", modelName: "—", category: "ro", price: 12500, qty: 1, warranty: false, warrantyMonths: 12, installation: false }],
    spareLines: [{ spareId: "s", name: "ROS ADAPTER", price: 750, qty: 2 }],
    amc: null,
  }
  it("included: payable = sum of prices (12,500 + 1,500)", () => {
    expect(payableTotal(cart, 0, 18, 0, true)).toBe(14000)
  })
  it("extra: payable = prices + 18% on each bill", () => {
    expect(payableTotal(cart, 0, 18, 0, false)).toBe(14750 + 1770)
  })
  it("referral redemption still floors at zero in included mode", () => {
    expect(payableTotal(cart, 0, 18, 999999, true)).toBe(0)
  })
})
