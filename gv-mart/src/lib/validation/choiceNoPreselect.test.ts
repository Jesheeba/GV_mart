import { describe, expect, it } from "vitest"
import { addressStepSchema, hasAddressDetails } from "./customer"
import { customerAddressSchema } from "./customerApp"
import { paymentDetailsSchema, PAYMENT_METHOD_REQUIRED } from "./sale"
import { rentOutSchema } from "./rentals"
import { emptyPoItem, isCompletePoItem, poItemSchema } from "./automation"

/** choice-no-preselect (build-docs/features/choice-no-preselect.md): either/or choices start unchosen. Address type/ownership: optional "Not set" since 2026-11-26. */

const messages = (r: { success: boolean; error?: { issues: { path: PropertyKey[]; message: string }[] } }) =>
  (r.error?.issues ?? []).map((i) => `${i.path.join(".")}:${i.message}`)

describe("addressStepSchema (admin customer form)", () => {
  const filled = { pincode: "600001", area: "Anna Nagar" }

  // Owner, 2026-11-26: type/ownership are dropdowns with "Not set", saved as null (replaces the earlier
  // "must choose" rule, so the two tests that asserted it were rewritten, not weakened).
  it("Not set: an address with details but no type/ownership saves, with both left empty (not defaulted)", () => {
    const r = addressStepSchema.safeParse(filled)
    expect(r.success).toBe(true)
    expect(r.data?.addressType).toBeUndefined()
    expect(r.data?.ownership).toBeUndefined()
  })

  it("Not set: a map pin with no type/ownership also saves", () => {
    expect(addressStepSchema.safeParse({ pincode: "", lat: 13.08, lng: 80.27 }).success).toBe(true)
  })

  it("Not set: one chosen, the other left Not set, is allowed", () => {
    expect(addressStepSchema.safeParse({ ...filled, ownership: "rental" }).success).toBe(true)
  })

  it("AC1/AC2: a contact saved with no address at all needs no type/ownership (nothing to describe)", () => {
    expect(addressStepSchema.safeParse({ pincode: "" }).success).toBe(true)
  })

  it("AC2: valid choices pass", () => {
    expect(addressStepSchema.safeParse({ ...filled, addressType: "commercial", ownership: "rental" }).success).toBe(true)
  })

  it("AC3: an edit payload carrying the saved values passes unchanged", () => {
    const r = addressStepSchema.safeParse({ ...filled, addressType: "residential", ownership: "own" })
    expect(r.success).toBe(true)
    expect(r.data).toMatchObject({ addressType: "residential", ownership: "own" })
  })

  it("rejects a value outside the enum", () => {
    expect(addressStepSchema.safeParse({ ...filled, addressType: "industrial", ownership: "own" }).success).toBe(false)
  })

  it("hasAddressDetails ignores whitespace-only text", () => {
    expect(hasAddressDetails({ pincode: "  ", area: " " })).toBe(false)
    expect(hasAddressDetails({ pincode: "", landmark: "Near temple" })).toBe(true)
  })
})

describe("customerAddressSchema (customer app AddressForm)", () => {
  const base = { fullAddress: "12, 2nd Street", area: "Anna Nagar", pincode: "600040" }

  it("Not set: the customer may leave type and ownership unset, same as the admin form", () => {
    const r = customerAddressSchema.safeParse(base)
    expect(r.success).toBe(true)
    expect(r.data?.addressType).toBeUndefined()
    expect(r.data?.ownership).toBeUndefined()
  })

  it("still rejects a value outside the enum", () => {
    expect(messages(customerAddressSchema.safeParse({ ...base, ownership: "leased" }))).toEqual(["ownership:customers.errors.ownershipRequired"])
  })

  it("AC2: valid choices pass", () => {
    expect(customerAddressSchema.safeParse({ ...base, addressType: "residential", ownership: "rental" }).success).toBe(true)
  })

  it("AC3: an edit payload with the saved values passes", () => {
    expect(customerAddressSchema.safeParse({ ...base, addressType: "commercial", ownership: "own", lat: 13, lng: 80 }).success).toBe(true)
  })
})

describe("paymentDetailsSchema (New Sale, Record payment)", () => {
  it("AC2: no method chosen fails with the method-required key the pages show under the buttons", () => {
    const r = paymentDetailsSchema.safeParse({ method: null, amountPaid: 100 })
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.message).toBe(PAYMENT_METHOD_REQUIRED)
  })

  it("AC2: missing method key fails the same way", () => {
    expect(paymentDetailsSchema.safeParse({ amountPaid: 100 }).error?.issues[0]?.message).toBe(PAYMENT_METHOD_REQUIRED)
  })

  it("AC2: a chosen method passes", () => {
    expect(paymentDetailsSchema.safeParse({ method: "cash", amountPaid: 100 }).success).toBe(true)
    expect(paymentDetailsSchema.safeParse({ method: "transfer", txnId: "T1", description: "NEFT", amountPaid: 100 }).success).toBe(true)
  })
})

describe("rentOutSchema (Rent out)", () => {
  const base = {
    customerId: "11111111-1111-4111-8111-111111111111",
    productId: "22222222-2222-4222-8222-222222222222",
    planId: "33333333-3333-4333-8333-333333333333",
    addressId: "44444444-4444-4444-8444-444444444444",
    startDate: "2026-11-26",
  }

  it("AC2: no payment method fails with the method-required key", () => {
    expect(messages(rentOutSchema.safeParse(base))).toEqual([`paymentMethod:${PAYMENT_METHOD_REQUIRED}`])
  })

  it("AC2: each method passes", () => {
    for (const paymentMethod of ["cash", "transfer", "upi"] as const) {
      expect(rentOutSchema.safeParse({ ...base, paymentMethod }).success).toBe(true)
    }
  })
})

describe("PO / bill line drafts", () => {
  it("AC1: a new line starts with no item type", () => {
    expect(emptyPoItem()).toEqual({ itemType: "", itemId: "", qty: 1, price: 0 })
  })

  it("AC2: a line without a type (or item) is not complete, so it is never submitted", () => {
    expect(isCompletePoItem(emptyPoItem())).toBe(false)
    expect(isCompletePoItem({ ...emptyPoItem(), itemId: "55555555-5555-4555-8555-555555555555" })).toBe(false)
    expect(isCompletePoItem({ ...emptyPoItem(), itemType: "spare" })).toBe(false)
  })

  it("AC2/AC3: a complete line (e.g. a prefilled one from the last bill) passes the submit schema", () => {
    const line = { itemType: "product" as const, itemId: "55555555-5555-4555-8555-555555555555", qty: 2, price: 10 }
    expect(isCompletePoItem(line)).toBe(true)
    expect(poItemSchema.safeParse(line).success).toBe(true)
  })
})
