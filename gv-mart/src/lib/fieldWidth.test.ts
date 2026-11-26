import { describe, expect, it } from "vitest"
import { twMerge } from "tailwind-merge"
import { FIELD_W } from "./fieldWidth"

describe("FIELD_W", () => {
  it("AC1: every value is a single fixed Tailwind width class, never w-full", () => {
    for (const cls of Object.values(FIELD_W)) {
      expect(cls).toMatch(/^w-\d+$/)
      expect(cls).not.toBe("w-full")
    }
  })

  it("AC1: overrides the Input primitive's w-full through tailwind-merge", () => {
    for (const cls of Object.values(FIELD_W)) {
      expect(twMerge("h-10 w-full min-w-0", cls)).toBe(`h-10 min-w-0 ${cls}`)
    }
  })

  it("AC1: amount width (w-32 = 128px) fits 10,00,000.00 at text-sm with px-3.5 padding", () => {
    const px = Number(FIELD_W.amount.slice(2)) * 4
    // ~8px per digit, ~4px per comma/dot at 14px; + 28px padding + 2px border
    const text = "10,00,000.00"
    const digits = text.replace(/\D/g, "").length
    expect(px).toBeGreaterThanOrEqual(digits * 8 + (text.length - digits) * 4 + 30)
  })

  it("AC1: mobile width fits 10 digits", () => {
    const px = Number(FIELD_W.mobile.slice(2)) * 4
    expect(px).toBeGreaterThanOrEqual(10 * 8 + 30)
  })
})
