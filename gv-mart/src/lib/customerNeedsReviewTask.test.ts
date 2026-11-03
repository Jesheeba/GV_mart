import { describe, expect, it } from "vitest"
import { CUSTOMER_NEEDS_REVIEW_REF_TYPE, hasLookupableContact, isCustomerNeedsReviewTask } from "./customerNeedsReviewTask"

describe("isCustomerNeedsReviewTask", () => {
  it("matches the exact ref_type", () => {
    expect(isCustomerNeedsReviewTask(CUSTOMER_NEEDS_REVIEW_REF_TYPE)).toBe(true)
    expect(isCustomerNeedsReviewTask("customer_needs_review")).toBe(true)
  })

  it("rejects other ref_types, null and undefined", () => {
    expect(isCustomerNeedsReviewTask("customer_outstanding")).toBe(false)
    expect(isCustomerNeedsReviewTask(null)).toBe(false)
    expect(isCustomerNeedsReviewTask(undefined)).toBe(false)
    expect(isCustomerNeedsReviewTask("")).toBe(false)
  })
})

describe("hasLookupableContact", () => {
  it("true when a mobile is present", () => {
    expect(hasLookupableContact("9876543210", null)).toBe(true)
  })

  it("true when only an email is present", () => {
    expect(hasLookupableContact(null, "a@b.com")).toBe(true)
  })

  it("false when both are null/undefined/blank", () => {
    expect(hasLookupableContact(null, null)).toBe(false)
    expect(hasLookupableContact(undefined, undefined)).toBe(false)
    expect(hasLookupableContact("  ", "   ")).toBe(false)
    expect(hasLookupableContact("", "")).toBe(false)
  })
})
