import { describe, expect, it } from "vitest"
import { canEditWaterHousehold, canSkipAddressPin, memberSchema, technicianCanSeeHealthCondition, waterProfileSchema } from "./customer"
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

describe("canSkipAddressPin", () => {
  it("allows master to save without a confirmed pin", () => {
    expect(canSkipAddressPin("master")).toBe(true)
  })

  it("still requires a pin for every other role", () => {
    expect(canSkipAddressPin("sales_admin")).toBe(false)
    expect(canSkipAddressPin("operation_admin")).toBe(false)
    expect(canSkipAddressPin(undefined)).toBe(false)
  })
})

describe("waterProfileSchema (FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md)", () => {
  it("pH outside 0–14 is rejected with the i18n key; 0 and 14 pass", () => {
    for (const bad of [-0.01, 14.01, 20, -5]) {
      const r = waterProfileSchema.safeParse({ waterPh: bad })
      expect(r.success, String(bad)).toBe(false)
      if (!r.success) expect(r.error.issues[0].message).toBe("customers.errors.waterPhInvalid")
    }
    expect(waterProfileSchema.safeParse({ waterPh: 0 }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ waterPh: 14 }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ waterPh: 6.5 }).success).toBe(true)
  })

  it("negative TDS is rejected with the i18n key", () => {
    const r = waterProfileSchema.safeParse({ waterTdsPpm: -1 })
    expect(r.success).toBe(false)
    if (!r.success) expect(r.error.issues[0].message).toBe("customers.errors.waterTdsInvalid")
    expect(waterProfileSchema.safeParse({ waterTdsPpm: 0 }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ waterTdsPpm: 570 }).success).toBe(true)
  })

  it("water_source accepts the 3 enum values and a blank placeholder", () => {
    for (const s of ["corporation", "borewater", "other", ""]) {
      expect(waterProfileSchema.safeParse({ waterSource: s }).success, s).toBe(true)
    }
    expect(waterProfileSchema.safeParse({ waterSource: "well" }).success).toBe(false)
  })

  it("waterSourceOther is only allowed when waterSource is 'other'", () => {
    const r = waterProfileSchema.safeParse({ waterSource: "corporation", waterSourceOther: "A well" })
    expect(r.success).toBe(false)
    if (!r.success) expect(r.error.issues[0].message).toBe("customers.errors.waterSourceOtherRequiresOther")
    expect(waterProfileSchema.safeParse({ waterSource: "other", waterSourceOther: "A well" }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ waterSource: "", waterSourceOther: "" }).success).toBe(true)
  })

  it("healthCondition accepts the 4 levels and a blank placeholder, rejects anything else", () => {
    for (const level of ["none", "normal", "medium", "high", ""]) {
      expect(waterProfileSchema.safeParse({ healthCondition: level }).success, level).toBe(true)
    }
    expect(waterProfileSchema.safeParse({ healthCondition: "critical" }).success).toBe(false)
  })
})

describe("canEditWaterHousehold (UI gate — DB is the real authority, see 20261108100000_customer_water_profile.sql)", () => {
  it("allows master, operation_admin and sales_admin", () => {
    expect(canEditWaterHousehold("master")).toBe(true)
    expect(canEditWaterHousehold("operation_admin")).toBe(true)
    expect(canEditWaterHousehold("sales_admin")).toBe(true)
  })
  it("refuses technician, customer, and no role", () => {
    expect(canEditWaterHousehold("technician")).toBe(false)
    expect(canEditWaterHousehold("customer")).toBe(false)
    expect(canEditWaterHousehold(undefined)).toBe(false)
    expect(canEditWaterHousehold(null)).toBe(false)
  })
})

describe("technicianCanSeeHealthCondition (UI gate — fails closed)", () => {
  it("is true only when the setting is explicitly true", () => {
    expect(technicianCanSeeHealthCondition(true)).toBe(true)
  })
  it("is false when off, unset, or the settings row hasn't loaded yet", () => {
    expect(technicianCanSeeHealthCondition(false)).toBe(false)
    expect(technicianCanSeeHealthCondition(null)).toBe(false)
    expect(technicianCanSeeHealthCondition(undefined)).toBe(false)
  })
})
