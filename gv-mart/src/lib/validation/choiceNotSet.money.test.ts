import { describe, expect, it } from "vitest"
import { paymentDetailsSchema, PAYMENT_METHOD_REQUIRED } from "./sale"
import { rentOutSchema } from "./rentals"
import { billCategorySchema, createExpenseSchema } from "./reports"
import { emptyPoItem, isCompletePoItem, poItemSchema } from "./automation"

/** choice-dropdowns-not-set (build-docs/features/choice-dropdowns-not-set.md), money/purchase fields — all class C:
 * ChoiceSelect emits "" for "Not set", and Save must be blocked with the field's required message. */

describe("payment method (New Sale, Record payment, Sell AMC on-site)", () => {
  it('AC2: "Not set" ("") blocks save with the method-required message', () => {
    const r = paymentDetailsSchema.safeParse({ method: "", amountPaid: 100 })
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.message).toBe(PAYMENT_METHOD_REQUIRED)
  })

  it("AC1: a new sale has no payment method pre-selected (null) and that blocks save too", () => {
    expect(paymentDetailsSchema.safeParse({ method: null, amountPaid: 100 }).error?.issues[0]?.message).toBe(PAYMENT_METHOD_REQUIRED)
  })

  it("AC3: a chosen method is kept as-is", () => {
    expect(paymentDetailsSchema.safeParse({ method: "cash", amountPaid: 0 }).data?.method).toBe("cash")
  })
})

describe("payment method (Rent out)", () => {
  const base = {
    customerId: "11111111-1111-4111-8111-111111111111",
    productId: "22222222-2222-4222-8222-222222222222",
    planId: "33333333-3333-4333-8333-333333333333",
    addressId: "44444444-4444-4444-8444-444444444444",
    startDate: "2026-11-26",
    txnId: "",
    paymentDescription: "",
  }

  it('AC2: "Not set" ("") blocks save with the method-required message on paymentMethod', () => {
    const issues = rentOutSchema.safeParse({ ...base, paymentMethod: "" }).error?.issues ?? []
    expect(issues.map((i) => `${i.path.join(".")}:${i.message}`)).toEqual([`paymentMethod:${PAYMENT_METHOD_REQUIRED}`])
  })

  it("AC2: Not set record pickers (product/plan/address \"\") keep their own required messages", () => {
    const issues = rentOutSchema.safeParse({ ...base, productId: "", planId: "", addressId: "", paymentMethod: "upi" }).error?.issues ?? []
    expect(issues.map((i) => i.message).sort()).toEqual(["rentals.errors.addressRequired", "rentals.errors.planRequired", "rentals.errors.productRequired"])
  })

  it("AC3: UPI is accepted", () => {
    expect(rentOutSchema.safeParse({ ...base, paymentMethod: "upi" }).success).toBe(true)
  })
})

describe("bill entry expense category", () => {
  it('AC1/AC2: a new bill starts at "Not set" ("") and that blocks save with the category-required message', () => {
    const r = billCategorySchema.safeParse("")
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.message).toBe("reports.errors.expenseCategoryRequired")
  })

  it("AC3: a chosen category (e.g. purchase) passes unchanged", () => {
    expect(billCategorySchema.parse("purchase")).toBe("purchase")
  })

  it("rejects a value outside the enum", () => {
    expect(billCategorySchema.safeParse("groceries").success).toBe(false)
  })
})

describe("log expense Under category (Accounts, P&L)", () => {
  it('AC2: "Not set" ("") blocks save with the category-required message', () => {
    const issues = createExpenseSchema.safeParse({ categoryId: "", amount: 10, date: "2026-11-26" }).error?.issues ?? []
    expect(issues.map((i) => `${i.path.join(".")}:${i.message}`)).toEqual(["categoryId:reports.errors.expenseCategoryRequired"])
  })

  it("AC3: a chosen category passes", () => {
    expect(createExpenseSchema.safeParse({ categoryId: "cat-1", amount: 10, date: "2026-11-26" }).success).toBe(true)
  })
})

describe("PO / bill line item type", () => {
  it('AC1: a new line starts at "Not set" and is incomplete until a type and item are chosen', () => {
    expect(emptyPoItem().itemType).toBe("")
    expect(isCompletePoItem(emptyPoItem())).toBe(false)
  })

  it('AC2: a line set back to "Not set" never passes the submit schema', () => {
    expect(poItemSchema.safeParse({ itemType: "", itemId: "55555555-5555-4555-8555-555555555555", qty: 1, price: 0 }).success).toBe(false)
  })
})
