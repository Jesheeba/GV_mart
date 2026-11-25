import { describe, expect, it } from "vitest"
import { hasReceivedQuantity, lineShortfall, normalizeInMobile, poPaymentActions, receivablePurchaseOrders, supplierWriteErrorKey } from "./purchase"
import { billEntrySchema, createPurchaseOrderSchema } from "./validation/automation"

const uuid = "11111111-1111-4111-8111-111111111111"

describe("vendor-flow-fixes", () => {
  describe("AC4 Bill Entry only offers POs awaiting delivery", () => {
    const pos = [
      { id: "d", status: "draft", supplier_id: "a" },
      { id: "s", status: "sent", supplier_id: "a" },
      { id: "s2", status: "sent", supplier_id: "b" },
      { id: "r", status: "received", supplier_id: "a" },
      { id: "p", status: "paid", supplier_id: "a" },
      { id: "c", status: "cancelled", supplier_id: "a" },
    ]
    it("hides draft, received, legacy paid and cancelled POs", () => {
      expect(receivablePurchaseOrders(pos, "").map((p) => p.id)).toEqual(["s", "s2"])
    })
    it("filters to the chosen supplier", () => {
      expect(receivablePurchaseOrders(pos, "b").map((p) => p.id)).toEqual(["s2"])
    })
  })

  describe("AC3 payment is separate from delivery", () => {
    it("master can pay a sent (not yet delivered) PO", () => {
      expect(poPaymentActions({ status: "sent", paid_at: null }, true)).toEqual({ canMarkPaid: true, canUndoPaid: false })
    })
    it("master can pay a received PO", () => {
      expect(poPaymentActions({ status: "received", paid_at: null }, true).canMarkPaid).toBe(true)
    })
    it("a paid PO offers undo, not pay", () => {
      expect(poPaymentActions({ status: "sent", paid_at: "2026-11-25T10:00:00Z" }, true)).toEqual({ canMarkPaid: false, canUndoPaid: true })
    })
    it("draft and cancelled POs cannot be paid", () => {
      expect(poPaymentActions({ status: "draft", paid_at: null }, true).canMarkPaid).toBe(false)
      expect(poPaymentActions({ status: "cancelled", paid_at: null }, true).canMarkPaid).toBe(false)
    })
    it("non-master sees no payment actions", () => {
      expect(poPaymentActions({ status: "sent", paid_at: null }, false)).toEqual({ canMarkPaid: false, canUndoPaid: false })
      expect(poPaymentActions({ status: "sent", paid_at: "x" }, false).canUndoPaid).toBe(false)
    })
  })

  describe("AC8 partial deliveries", () => {
    it("shortfall is ordered minus received", () => {
      expect(lineShortfall({ qty: 10, received_qty: 7 })).toBe(3)
    })
    it("no shortfall before delivery or when over-delivered", () => {
      expect(lineShortfall({ qty: 10, received_qty: null })).toBe(0)
      expect(lineShortfall({ qty: 10, received_qty: 12 })).toBe(0)
    })
    it("an all-zero receipt is not allowed", () => {
      expect(hasReceivedQuantity([0, 0])).toBe(false)
      expect(hasReceivedQuantity([])).toBe(false)
      expect(hasReceivedQuantity([Number.NaN])).toBe(false)
      expect(hasReceivedQuantity([0, 2])).toBe(true)
    })
  })

  describe("AC7 price and quantity validation", () => {
    const line = { itemType: "spare" as const, itemId: uuid, qty: 2, price: 50 }
    it("accepts a valid PO", () => {
      expect(createPurchaseOrderSchema.safeParse({ supplierId: uuid, items: [line] }).success).toBe(true)
    })
    it("rejects a ₹0 line", () => {
      const r = createPurchaseOrderSchema.safeParse({ supplierId: uuid, items: [{ ...line, price: 0 }] })
      expect(r.success).toBe(false)
      expect(r.error?.issues[0].message).toBe("purchase.errors.pricePositive")
    })
    it("rejects a negative price", () => {
      expect(createPurchaseOrderSchema.safeParse({ supplierId: uuid, items: [{ ...line, price: -1 }] }).success).toBe(false)
    })
    it("rejects a bill with negative GST", () => {
      const r = billEntrySchema.safeParse({ supplierId: uuid, poId: "", items: [line], gst: -1, billDate: "2026-11-25" })
      expect(r.success).toBe(false)
      expect(r.error?.issues[0].message).toBe("purchase.errors.gstNonNegative")
    })
    it("rejects a PO with no supplier", () => {
      expect(createPurchaseOrderSchema.safeParse({ supplierId: "", items: [line] }).success).toBe(false)
    })
  })

  describe("AC10 supplier WhatsApp number", () => {
    it("normalises +91 and spaces to 10 digits, like the DB", () => {
      expect(normalizeInMobile("+91 98765 43210")).toBe("9876543210")
      expect(normalizeInMobile("098765-43210")).toBe("9876543210")
    })
    it("rejects short or empty numbers", () => {
      expect(normalizeInMobile("12345")).toBeNull()
      expect(normalizeInMobile("")).toBeNull()
      expect(normalizeInMobile(null)).toBeNull()
    })
  })

  describe("AC11 supplier write errors are explained", () => {
    it("duplicate link and in-use delete map to messages", () => {
      expect(supplierWriteErrorKey({ code: "23505" })).toBe("suppliers.duplicateLink")
      expect(supplierWriteErrorKey({ code: "23503" })).toBe("suppliers.cannotDelete")
    })
    it("other errors are shown as is", () => {
      expect(supplierWriteErrorKey(new Error("boom"))).toBeNull()
      expect(supplierWriteErrorKey(null)).toBeNull()
    })
  })
})
