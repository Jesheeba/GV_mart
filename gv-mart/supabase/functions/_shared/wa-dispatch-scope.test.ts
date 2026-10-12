import { describe, expect, it } from "vitest"
import { DISPATCH_V2_OFF, last10Digits, parseDispatchV2Scope, v2Active, v2AppliesTo } from "./wa-dispatch-scope"

const row = (o: Record<string, unknown>) => ({ wa_dispatch_v2_enabled: true, wa_dispatch_v2_scope: "numbers", wa_dispatch_v2_numbers: [], ...o })

describe("parseDispatchV2Scope", () => {
  it("anything unexpected is OFF", () => {
    for (const bad of [null, undefined, "x", 3, {}, { wa_dispatch_v2_enabled: "true" }, { wa_dispatch_v2_enabled: false, wa_dispatch_v2_scope: "org" }]) {
      expect(parseDispatchV2Scope(bad)).toEqual(DISPATCH_V2_OFF)
    }
  })
  it("a missing scope column means numbers (never org)", () => {
    expect(parseDispatchV2Scope({ wa_dispatch_v2_enabled: true }).scope).toBe("numbers")
    expect(parseDispatchV2Scope(row({ wa_dispatch_v2_scope: "everyone" })).scope).toBe("numbers")
  })
  it("keeps only valid ten-digit numbers, normalised to the last ten digits", () => {
    const s = parseDispatchV2Scope(row({ wa_dispatch_v2_numbers: ["9000000001", "+91 90000 00002", "12345", 7, null, "919000000003"] }))
    expect(s.numbers).toEqual(["9000000001", "9000000002", "9000000003"])
  })
})

describe("v2AppliesTo / v2Active", () => {
  it("empty list: nobody, and v2 is not active", () => {
    const s = parseDispatchV2Scope(row({}))
    expect(v2AppliesTo(s, "9000000001")).toBe(false)
    expect(v2Active(s)).toBe(false)
  })
  it("numbers: only the listed, in any formatting", () => {
    const s = parseDispatchV2Scope(row({ wa_dispatch_v2_numbers: ["9000000001"] }))
    expect(v2Active(s)).toBe(true)
    expect(v2AppliesTo(s, "9000000001")).toBe(true)
    expect(v2AppliesTo(s, "919000000001")).toBe(true)
    expect(v2AppliesTo(s, "+91-90000-00001")).toBe(true)
    expect(v2AppliesTo(s, "9000000002")).toBe(false)
    expect(v2AppliesTo(s, null)).toBe(false)
    expect(v2AppliesTo(s, "")).toBe(false)
  })
  it("org scope: everyone, but only when explicitly chosen", () => {
    const s = parseDispatchV2Scope(row({ wa_dispatch_v2_scope: "org" }))
    expect(v2Active(s)).toBe(true)
    expect(v2AppliesTo(s, "9000000009")).toBe(true)
    expect(v2AppliesTo(s, null)).toBe(true)
  })
  it("flag off: nobody, whatever the list or scope", () => {
    const s = parseDispatchV2Scope(row({ wa_dispatch_v2_enabled: false, wa_dispatch_v2_scope: "org", wa_dispatch_v2_numbers: ["9000000001"] }))
    expect(v2AppliesTo(s, "9000000001")).toBe(false)
    expect(v2Active(s)).toBe(false)
  })
  it("last10Digits", () => {
    expect(last10Digits("+91 98765 43210")).toBe("9876543210")
    expect(last10Digits(undefined)).toBe("")
  })
})
