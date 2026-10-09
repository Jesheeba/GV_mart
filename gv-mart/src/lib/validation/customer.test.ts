import { describe, expect, it } from "vitest"
import { memberSchema } from "./customer"
import { customerMemberSchema } from "./customerApp"

const base = { name: "Asha Rao", mobile: "9876543210" }

describe("member email (optional)", () => {
  it("is optional: missing, empty and whitespace-only all pass", () => {
    expect(memberSchema.safeParse(base).success).toBe(true)
    expect(memberSchema.safeParse({ ...base, email: "" }).success).toBe(true)
    expect(memberSchema.safeParse({ ...base, email: "   " }).success).toBe(true)
  })
  it("accepts a normal address and trims it", () => {
    const r = memberSchema.safeParse({ ...base, email: "  asha@example.co.in " })
    expect(r.success).toBe(true)
    if (r.success) expect(r.data.email).toBe("asha@example.co.in")
  })
  it("rejects malformed addresses with the i18n key", () => {
    for (const bad of ["asha", "asha@", "@example.com", "asha@example", "a b@example.com"]) {
      const r = memberSchema.safeParse({ ...base, email: bad })
      expect(r.success, bad).toBe(false)
      if (!r.success) expect(r.error.issues[0].message).toBe("customers.errors.emailInvalid")
    }
  })
  it("still requires name and a valid mobile", () => {
    expect(memberSchema.safeParse({ name: "A", mobile: "9876543210" }).success).toBe(false)
    expect(memberSchema.safeParse({ name: "Asha Rao", mobile: "1234567890" }).success).toBe(false)
  })
  it("customer-app member form takes the same optional profession and email", () => {
    expect(customerMemberSchema.safeParse({ ...base, profession: "Teacher", email: "" }).success).toBe(true)
    const r = customerMemberSchema.safeParse({ ...base, email: "nope" })
    expect(r.success).toBe(false)
    if (!r.success) expect(r.error.issues[0].message).toBe("customerApp.errors.emailInvalid")
  })
})
