import { describe, expect, it } from "vitest"
import { discountPercentOf, maxQuotationDiscount, quotationDiscountProblem } from "./quotationDiscount"

describe("quotationDiscountProblem (AC4: same cap as a sale, reason required)", () => {
  it("no discount is fine without a reason", () => {
    expect(quotationDiscountProblem(20000, 0, "", 10)).toBeNull()
  })
  it("₹ discount up to the cap with a reason is fine", () => {
    expect(quotationDiscountProblem(20000, 2000, "bulk order", 10)).toBeNull()
  })
  it("over the cap is refused, with the max shown", () => {
    expect(quotationDiscountProblem(20000, 2000.01, "x", 10)).toEqual({ key: "quotations.discount.errorOverCap", params: { percent: 10, max: 2000 } })
  })
  it("discount without a reason (or only spaces) is refused", () => {
    expect(quotationDiscountProblem(20000, 500, "   ", 10)).toEqual({ key: "quotations.discount.errorReason" })
  })
  it("negative or not-a-number is refused", () => {
    expect(quotationDiscountProblem(20000, -1, "x", 10)).toEqual({ key: "quotations.discount.errorNegative" })
    expect(quotationDiscountProblem(20000, Number.NaN, "x", 10)).toEqual({ key: "quotations.discount.errorNegative" })
  })
})

describe("maxQuotationDiscount / discountPercentOf", () => {
  it("cap is rounded to paise", () => {
    expect(maxQuotationDiscount(333.33, 10)).toBe(33.33)
  })
  it("₹ → % for the sale step (2 decimals); empty cart → 0", () => {
    expect(discountPercentOf(31000, 2000)).toBe(6.45)
    expect(discountPercentOf(0, 100)).toBe(0)
  })
})
