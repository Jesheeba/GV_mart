import { describe, expect, it } from "vitest"
import en from "@/lib/i18n/en.json"
import ta from "@/lib/i18n/ta.json"
import { EMPTY_REFERRER, REFERRER_KINDS, existingCustomerMatch, isReferrerComplete, quickAddCustomerSchema, switchReferrerKind } from "./referrer"
import type { DuplicateContactMatch } from "./duplicateContactWarning"

const match = (source: "customer" | "lead", id: string): DuplicateContactMatch => ({
  source,
  id,
  name: `n-${id}`,
  mobile: "9876543210",
  email: null,
  created_at: "2026-11-26T00:00:00Z",
  ticket_count: 0,
  invoice_count: 0,
})

describe("AC1/AC2 referrer kinds", () => {
  it("offers technician, staff, customer, other and none", () => {
    expect([...REFERRER_KINDS].sort()).toEqual(["customer", "none", "other", "staff", "technician"])
  })
  it("never offers walk-in or lead as a referrer (they are Sources)", () => {
    expect(REFERRER_KINDS).not.toContain("walk_in" as never)
    expect(REFERRER_KINDS).not.toContain("lead" as never)
  })
  it("has en + ta labels for every kind", () => {
    for (const k of REFERRER_KINDS) {
      expect(en.referrer.kind[k]).toBeTruthy()
      expect(ta.referrer.kind[k]).toBeTruthy()
    }
  })
})

describe("edge: switching kind clears the other kinds' fields", () => {
  const picked = { kind: "customer" as const, userId: "", customerId: "c1", name: "Asha", phone: "9876543210" }
  it("customer -> other drops the picked customer", () => {
    expect(switchReferrerKind(picked, "other")).toEqual({ ...EMPTY_REFERRER, kind: "other" })
  })
  it("technician -> staff drops the technician id", () => {
    expect(switchReferrerKind({ ...EMPTY_REFERRER, kind: "technician", userId: "u1" }, "staff").userId).toBe("")
  })
  it("same kind keeps the value", () => {
    expect(switchReferrerKind(picked, "customer")).toBe(picked)
  })
})

describe("isReferrerComplete", () => {
  it("needs the field the kind owns", () => {
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "technician" })).toBe(false)
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "staff", userId: "u1" })).toBe(true)
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "customer", name: "Asha" })).toBe(false)
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "customer", customerId: "c1" })).toBe(true)
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "other", name: "   " })).toBe(false)
    expect(isReferrerComplete({ ...EMPTY_REFERRER, kind: "other", name: "Ravi" })).toBe(true)
    expect(isReferrerComplete(EMPTY_REFERRER)).toBe(false)
  })
})

describe("AC3 quick-add asks name, mobile, optional area", () => {
  it("accepts name + mobile without area", () => {
    expect(quickAddCustomerSchema.safeParse({ name: "Asha Rao", mobile: "9876543210" }).success).toBe(true)
    expect(quickAddCustomerSchema.safeParse({ name: "Asha Rao", mobile: "9876543210", area: "" }).success).toBe(true)
  })
  it("trims and keeps area when given", () => {
    const r = quickAddCustomerSchema.parse({ name: "  Asha Rao ", mobile: " 9876543210 ", area: " Anna Nagar " })
    expect(r).toEqual({ name: "Asha Rao", mobile: "9876543210", area: "Anna Nagar" })
  })
  it("rejects a missing/short name", () => {
    expect(quickAddCustomerSchema.safeParse({ name: " A ", mobile: "9876543210" }).success).toBe(false)
  })
  it("rejects invalid mobiles (same rule as the customer form)", () => {
    for (const mobile of ["", "12345", "1234567890", "98765432101", "98765abcde"]) {
      expect(quickAddCustomerSchema.safeParse({ name: "Asha Rao", mobile }).success).toBe(false)
    }
  })
  it("has en + ta strings for the dialog", () => {
    for (const key of Object.keys(en.referrer.quickAdd) as (keyof typeof en.referrer.quickAdd)[]) {
      expect(ta.referrer.quickAdd[key]).toBeTruthy()
    }
  })
})

describe("AC4 existing mobile offers the existing customer", () => {
  it("picks the customer match, ignoring lead matches", () => {
    expect(existingCustomerMatch([match("lead", "l1"), match("customer", "c1")])?.id).toBe("c1")
  })
  it("returns null when only leads or nothing match", () => {
    expect(existingCustomerMatch([match("lead", "l1")])).toBeNull()
    expect(existingCustomerMatch([])).toBeNull()
    expect(existingCustomerMatch(undefined)).toBeNull()
  })
})
