import { describe, expect, it } from "vitest"
import { normalizeIndianMobile, normalizeOptionalIndianMobile } from "./mobile"

describe("normalizeIndianMobile", () => {
  it("accepts a plain 10-digit number", () => {
    expect(normalizeIndianMobile("9876543210")).toEqual({ ok: true, value: "9876543210" })
  })

  it("strips +91 country code", () => {
    expect(normalizeIndianMobile("+91 98765 43210")).toEqual({ ok: true, value: "9876543210" })
  })

  it("strips a bare 91 country code with no plus", () => {
    expect(normalizeIndianMobile("9198765 43210")).toEqual({ ok: true, value: "9876543210" })
  })

  it("strips a leading trunk 0", () => {
    expect(normalizeIndianMobile("09876543210")).toEqual({ ok: true, value: "9876543210" })
  })

  it("trims surrounding whitespace and separators", () => {
    expect(normalizeIndianMobile("  98765-43210  ")).toEqual({ ok: true, value: "9876543210" })
  })

  it("rejects empty input", () => {
    expect(normalizeIndianMobile("")).toEqual({ ok: false, reason: "empty" })
    expect(normalizeIndianMobile("   ")).toEqual({ ok: false, reason: "empty" })
    expect(normalizeIndianMobile(null)).toEqual({ ok: false, reason: "empty" })
    expect(normalizeIndianMobile(undefined)).toEqual({ ok: false, reason: "empty" })
  })

  it("rejects a number that starts 0-5 even after stripping", () => {
    expect(normalizeIndianMobile("5876543210")).toEqual({ ok: false, reason: "invalid" })
  })

  it("rejects too few or too many digits", () => {
    expect(normalizeIndianMobile("987654321")).toEqual({ ok: false, reason: "invalid" })
    expect(normalizeIndianMobile("98765432100")).toEqual({ ok: false, reason: "invalid" })
  })

  it("does not misfire on a 12-digit number that doesn't actually start with 91", () => {
    // 12 raw digits but not a 91-prefixed number -- must be rejected, not blindly sliced.
    expect(normalizeIndianMobile("123456789012")).toEqual({ ok: false, reason: "invalid" })
  })
})

describe("normalizeOptionalIndianMobile", () => {
  it("treats blank as valid null (alternate mobile is optional)", () => {
    expect(normalizeOptionalIndianMobile("")).toEqual({ ok: true, value: null })
    expect(normalizeOptionalIndianMobile("   ")).toEqual({ ok: true, value: null })
    expect(normalizeOptionalIndianMobile(null)).toEqual({ ok: true, value: null })
  })

  it("still validates a non-blank value", () => {
    expect(normalizeOptionalIndianMobile("+91 98765 43210")).toEqual({ ok: true, value: "9876543210" })
    expect(normalizeOptionalIndianMobile("123")).toEqual({ ok: false, reason: "invalid" })
  })
})
