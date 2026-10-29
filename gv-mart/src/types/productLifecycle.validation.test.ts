import { describe, expect, it } from "vitest"
import { isPositiveInteger, validateLifetime, validateSpareSchedules } from "./productLifecycle"

describe("isPositiveInteger", () => {
  it("accepts positive integers", () => {
    expect(isPositiveInteger(1)).toBe(true)
    expect(isPositiveInteger(12)).toBe(true)
  })
  it("rejects zero, negatives and non-integers", () => {
    expect(isPositiveInteger(0)).toBe(false)
    expect(isPositiveInteger(-5)).toBe(false)
    expect(isPositiveInteger(1.5)).toBe(false)
    expect(isPositiveInteger(Number.NaN)).toBe(false)
  })
})

describe("validateLifetime", () => {
  it("passes for a positive integer value", () => {
    const result = validateLifetime({ lifetimeValue: 12, lifetimeUnit: "months" })
    expect(result.valid).toBe(true)
    expect(result.errors).toEqual({})
  })

  it("passes for years unit too — unit itself is never invalid", () => {
    const result = validateLifetime({ lifetimeValue: 5, lifetimeUnit: "years" })
    expect(result.valid).toBe(true)
  })

  it("fails for zero", () => {
    const result = validateLifetime({ lifetimeValue: 0, lifetimeUnit: "months" })
    expect(result.valid).toBe(false)
    expect(result.errors.lifetimeValue).toBe("lifetimeValueInvalid")
  })

  it("fails for a negative value", () => {
    const result = validateLifetime({ lifetimeValue: -3, lifetimeUnit: "months" })
    expect(result.valid).toBe(false)
  })

  it("fails for a non-integer value", () => {
    const result = validateLifetime({ lifetimeValue: 2.5, lifetimeUnit: "years" })
    expect(result.valid).toBe(false)
  })

  it("fails for NaN (e.g. an empty input parsed with Number())", () => {
    const result = validateLifetime({ lifetimeValue: Number.NaN, lifetimeUnit: "months" })
    expect(result.valid).toBe(false)
  })
})

describe("validateSpareSchedules", () => {
  it("passes for a well-formed row with a spare picked", () => {
    const result = validateSpareSchedules([{ spareId: "spare-1", label: "Pre-filter", intervalValue: 6, intervalUnit: "months" }])
    expect(result.valid).toBe(true)
    expect(result.rowErrors).toEqual([{}])
  })

  it("passes for a free-text row with no spare picked", () => {
    const result = validateSpareSchedules([{ spareId: null, label: "Anode rod", intervalValue: 2, intervalUnit: "years" }])
    expect(result.valid).toBe(true)
  })

  it("fails a row with an empty label", () => {
    const result = validateSpareSchedules([{ spareId: null, label: "", intervalValue: 6, intervalUnit: "months" }])
    expect(result.valid).toBe(false)
    expect(result.rowErrors[0].label).toBe("labelRequired")
  })

  it("fails a row whose label is only whitespace", () => {
    const result = validateSpareSchedules([{ spareId: null, label: "   ", intervalValue: 6, intervalUnit: "months" }])
    expect(result.valid).toBe(false)
    expect(result.rowErrors[0].label).toBe("labelRequired")
  })

  it("fails a row with a zero or non-integer interval", () => {
    const zero = validateSpareSchedules([{ spareId: null, label: "Filter", intervalValue: 0, intervalUnit: "months" }])
    expect(zero.valid).toBe(false)
    expect(zero.rowErrors[0].intervalValue).toBe("intervalValueInvalid")

    const fractional = validateSpareSchedules([{ spareId: null, label: "Filter", intervalValue: 1.5, intervalUnit: "months" }])
    expect(fractional.valid).toBe(false)
  })

  it("allows duplicate labels across rows on the same product — not deduped", () => {
    const result = validateSpareSchedules([
      { spareId: null, label: "Filter", intervalValue: 6, intervalUnit: "months" },
      { spareId: null, label: "Filter", intervalValue: 12, intervalUnit: "months" },
    ])
    expect(result.valid).toBe(true)
    expect(result.rowErrors).toEqual([{}, {}])
  })

  it("validates each row independently — one bad row doesn't block the others", () => {
    const result = validateSpareSchedules([
      { spareId: null, label: "Filter", intervalValue: 6, intervalUnit: "months" },
      { spareId: null, label: "", intervalValue: -1, intervalUnit: "years" },
    ])
    expect(result.valid).toBe(false)
    expect(result.rowErrors[0]).toEqual({})
    expect(result.rowErrors[1]).toEqual({ label: "labelRequired", intervalValue: "intervalValueInvalid" })
  })

  it("handles an empty row list as valid (no rows to fail)", () => {
    const result = validateSpareSchedules([])
    expect(result.valid).toBe(true)
    expect(result.rowErrors).toEqual([])
  })
})
