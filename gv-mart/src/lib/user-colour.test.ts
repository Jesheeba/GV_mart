import { describe, expect, it } from "vitest"
import { userColour } from "./user-colour"

describe("userColour", () => {
  it("uses the explicit colour when given", () => {
    expect(userColour("abc", "#112233")).toBe("#112233")
  })
  it("is deterministic for the same id", () => {
    expect(userColour("00000000-0000-0000-0000-000000000001")).toBe(userColour("00000000-0000-0000-0000-000000000001"))
  })
  it("differs for different ids (not a constant fallback)", () => {
    const a = userColour("00000000-0000-0000-0000-000000000001")
    const b = userColour("00000000-0000-0000-0000-000000000002")
    expect(a).not.toBe(b)
  })
  it("falls back when the explicit colour is null, undefined or empty", () => {
    const fallback = userColour("x")
    expect(userColour("x", null)).toBe(fallback)
    expect(userColour("x", undefined)).toBe(fallback)
    expect(userColour("x", "")).toBe(fallback)
  })
})
