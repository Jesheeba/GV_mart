import { describe, expect, it } from "vitest"
import {
  discountNeedsApproval,
  enquiryLeadSchema,
  isDiscountBlocked,
  ratingSchema,
  roChecklistSchema,
  servicePaymentSchema,
  showsGoogleReviewLink,
} from "./technician"

describe("isDiscountBlocked", () => {
  it("blocks negative percent", () => {
    expect(isDiscountBlocked(-1, 10)).toBe(true)
  })
  it("blocks percent above adminMax", () => {
    expect(isDiscountBlocked(10.01, 10)).toBe(true)
  })
  it("allows percent exactly at adminMax", () => {
    expect(isDiscountBlocked(10, 10)).toBe(false)
  })
  it("allows 0", () => {
    expect(isDiscountBlocked(0, 10)).toBe(false)
  })
  it("allows a normal in-range value", () => {
    expect(isDiscountBlocked(5, 10)).toBe(false)
  })
})

describe("discountNeedsApproval", () => {
  it("does not need approval exactly at techMax", () => {
    expect(discountNeedsApproval(5, 5, 10)).toBe(false)
  })
  it("needs approval just above techMax", () => {
    expect(discountNeedsApproval(5.01, 5, 10)).toBe(true)
  })
  it("needs approval exactly at adminMax", () => {
    expect(discountNeedsApproval(10, 5, 10)).toBe(true)
  })
  it("does not need approval below techMax", () => {
    expect(discountNeedsApproval(2, 5, 10)).toBe(false)
  })
  it("does not need approval (already blocked) above adminMax", () => {
    // discountNeedsApproval alone would be false past adminMax too — blocking
    // is isDiscountBlocked's job, but the band function shouldn't claim
    // "needs approval" once out of its own range either.
    expect(discountNeedsApproval(15, 5, 10)).toBe(false)
  })
})

describe("showsGoogleReviewLink", () => {
  it("shows at exactly minStars", () => {
    expect(showsGoogleReviewLink(4, 4)).toBe(true)
  })
  it("shows above minStars", () => {
    expect(showsGoogleReviewLink(5, 4)).toBe(true)
  })
  it("hides below minStars", () => {
    expect(showsGoogleReviewLink(3, 4)).toBe(false)
  })
})

describe("roChecklistSchema", () => {
  it("accepts a fully-filled valid payload", () => {
    const result = roChecklistSchema.safeParse({
      tdsBefore: 120,
      tdsAfter: 15,
      tankCleaned: true,
      productExplained: false,
      clientName: "Ravi Kumar",
    })
    expect(result.success).toBe(true)
  })

  it("accepts nullable booleans and omitted optional tds fields", () => {
    const result = roChecklistSchema.safeParse({
      tankCleaned: null,
      productExplained: null,
      clientName: "Ravi",
    })
    expect(result.success).toBe(true)
  })

  it("rejects a negative tdsBefore", () => {
    const result = roChecklistSchema.safeParse({
      tdsBefore: -1,
      tankCleaned: true,
      productExplained: true,
      clientName: "Ravi",
    })
    expect(result.success).toBe(false)
  })

  it("rejects an empty/whitespace clientName", () => {
    const result = roChecklistSchema.safeParse({
      tankCleaned: true,
      productExplained: true,
      clientName: "   ",
    })
    expect(result.success).toBe(false)
  })

  it("rejects a missing tankCleaned (booleans are required, only their null-ness is optional)", () => {
    const result = roChecklistSchema.safeParse({
      productExplained: true,
      clientName: "Ravi",
    })
    expect(result.success).toBe(false)
  })
})

describe("servicePaymentSchema", () => {
  it("accepts cash with no txnId/description", () => {
    const result = servicePaymentSchema.safeParse({ method: "cash" })
    expect(result.success).toBe(true)
  })

  it("accepts transfer with txnId and description", () => {
    const result = servicePaymentSchema.safeParse({
      method: "transfer",
      txnId: "TXN123",
      description: "Paid via UPI",
    })
    expect(result.success).toBe(true)
  })

  it("rejects transfer with empty txnId", () => {
    const result = servicePaymentSchema.safeParse({
      method: "transfer",
      txnId: "",
      description: "Paid via UPI",
    })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(result.error.issues.some((i) => i.path.join(".") === "txnId" && i.message === "technician.errors.txnIdRequired")).toBe(true)
    }
  })

  it("rejects transfer with missing description", () => {
    const result = servicePaymentSchema.safeParse({
      method: "transfer",
      txnId: "TXN123",
    })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(
        result.error.issues.some((i) => i.path.join(".") === "description" && i.message === "technician.errors.paymentDescriptionRequired")
      ).toBe(true)
    }
  })

  it("rejects an invalid method value", () => {
    const result = servicePaymentSchema.safeParse({ method: "upi" })
    expect(result.success).toBe(false)
  })
})

describe("enquiryLeadSchema", () => {
  it("accepts a valid payload with mobile", () => {
    const result = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      mobile: "9876543210",
      enquiryType: "price",
      note: "wants a discount",
    })
    expect(result.success).toBe(true)
  })

  it("accepts an omitted/empty mobile (optional)", () => {
    const result = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      enquiryType: "online",
    })
    expect(result.success).toBe(true)
    const result2 = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      mobile: "",
      enquiryType: "online",
    })
    expect(result2.success).toBe(true)
  })

  it("rejects a name shorter than 2 characters", () => {
    const result = enquiryLeadSchema.safeParse({ name: "R", enquiryType: "price" })
    expect(result.success).toBe(false)
  })

  it("rejects a mobile that doesn't start with 6-9", () => {
    const result = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      mobile: "5876543210",
      enquiryType: "price",
    })
    expect(result.success).toBe(false)
  })

  it("rejects a mobile with the wrong digit count", () => {
    const result = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      mobile: "98765432100",
      enquiryType: "price",
    })
    expect(result.success).toBe(false)
  })

  it("rejects an invalid enquiryType", () => {
    const result = enquiryLeadSchema.safeParse({
      name: "Ravi Kumar",
      enquiryType: "not_a_real_type",
    })
    expect(result.success).toBe(false)
  })
})

describe("ratingSchema", () => {
  it("accepts 5 stars with no lowRatingReason", () => {
    const result = ratingSchema.safeParse({ stars: 5 })
    expect(result.success).toBe(true)
  })

  it("accepts exactly 3 stars with no lowRatingReason (boundary: >=3 doesn't require a reason)", () => {
    const result = ratingSchema.safeParse({ stars: 3 })
    expect(result.success).toBe(true)
  })

  it("rejects 2 stars with no lowRatingReason", () => {
    const result = ratingSchema.safeParse({ stars: 2 })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(
        result.error.issues.some((i) => i.path.join(".") === "lowRatingReason" && i.message === "technician.errors.lowRatingReasonRequired")
      ).toBe(true)
    }
  })

  it("accepts 2 stars when lowRatingReason is provided", () => {
    const result = ratingSchema.safeParse({ stars: 2, lowRatingReason: "Leaking pipe" })
    expect(result.success).toBe(true)
  })

  it("coerces a numeric string for stars", () => {
    const result = ratingSchema.safeParse({ stars: "4" })
    expect(result.success).toBe(true)
    if (result.success) expect(result.data.stars).toBe(4)
  })

  it("rejects stars below 1 or above 5", () => {
    expect(ratingSchema.safeParse({ stars: 0 }).success).toBe(false)
    expect(ratingSchema.safeParse({ stars: 6 }).success).toBe(false)
  })
})
