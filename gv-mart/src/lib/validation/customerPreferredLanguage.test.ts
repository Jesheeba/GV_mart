import { describe, expect, it } from "vitest"
import { peopleStepSchema } from "./customer"

const base = { members: [{ name: "Priya Raman", mobile: "9876543210" }], primaryIndex: 0 }

describe("peopleStepSchema.preferredLanguage", () => {
  it("is optional", () => {
    expect(peopleStepSchema.safeParse(base).success).toBe(true)
  })
  it("accepts en, ta and the empty (not set) value", () => {
    for (const v of ["en", "ta", ""]) {
      expect(peopleStepSchema.safeParse({ ...base, preferredLanguage: v }).success, v).toBe(true)
    }
  })
  it("refuses any other language", () => {
    expect(peopleStepSchema.safeParse({ ...base, preferredLanguage: "fr" }).success).toBe(false)
    expect(peopleStepSchema.safeParse({ ...base, preferredLanguage: "EN" }).success).toBe(false)
  })
})
