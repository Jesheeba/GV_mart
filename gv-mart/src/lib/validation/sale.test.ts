import { describe, expect, it } from "vitest"
import { discountNeedsApproval, isDiscountBlocked, paymentDetailsSchema } from "./sale"

describe("isDiscountBlocked", () => {
  it("blocks negative percent", () => {
    expect(isDiscountBlocked(-0.01, 10)).toBe(true)
  })
  it("blocks percent above adminMax", () => {
    expect(isDiscountBlocked(10.5, 10)).toBe(true)
  })
  it("allows percent exactly at adminMax", () => {
    expect(isDiscountBlocked(10, 10)).toBe(false)
  })
  it("allows 0", () => {
    expect(isDiscountBlocked(0, 10)).toBe(false)
  })
})

describe("discountNeedsApproval", () => {
  it("does not need approval exactly at techMax (5% free band, v2.2 §6.1)", () => {
    expect(discountNeedsApproval(5, 5, 10)).toBe(false)
  })
  it("needs approval just above techMax", () => {
    expect(discountNeedsApproval(5.01, 5, 10)).toBe(true)
  })
  it("needs approval exactly at adminMax", () => {
    expect(discountNeedsApproval(10, 5, 10)).toBe(true)
  })
  it("no longer 'needs approval' once past adminMax (isDiscountBlocked owns that range)", () => {
    expect(discountNeedsApproval(10.01, 5, 10)).toBe(false)
  })
  it("does not need approval below techMax", () => {
    expect(discountNeedsApproval(1, 5, 10)).toBe(false)
  })
})

describe("paymentDetailsSchema", () => {
  it("accepts cash with no txnId/description", () => {
    expect(paymentDetailsSchema.safeParse({ method: "cash" }).success).toBe(true)
  })

  it("accepts transfer with txnId and description", () => {
    const result = paymentDetailsSchema.safeParse({
      method: "transfer",
      txnId: "TXN789",
      description: "Bank transfer",
    })
    expect(result.success).toBe(true)
  })

  it("rejects transfer with missing txnId", () => {
    const result = paymentDetailsSchema.safeParse({
      method: "transfer",
      description: "Bank transfer",
    })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(result.error.issues.some((i) => i.path.join(".") === "txnId" && i.message === "sales.errors.txnIdRequired")).toBe(true)
    }
  })

  it("rejects transfer with empty description", () => {
    const result = paymentDetailsSchema.safeParse({
      method: "transfer",
      txnId: "TXN789",
      description: "",
    })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(
        result.error.issues.some((i) => i.path.join(".") === "description" && i.message === "sales.errors.paymentDescriptionRequired")
      ).toBe(true)
    }
  })

  it("rejects an invalid method", () => {
    expect(paymentDetailsSchema.safeParse({ method: "card" }).success).toBe(false)
  })

  it("rejects a txnId over 120 characters", () => {
    const result = paymentDetailsSchema.safeParse({
      method: "transfer",
      txnId: "a".repeat(121),
      description: "ok",
    })
    expect(result.success).toBe(false)
  })
})
