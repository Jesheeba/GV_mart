import { describe, expect, it } from "vitest"
import { parseTestNumbers } from "./WaTestModeSwitch"

describe("parseTestNumbers", () => {
  it("accepts one number per line, commas, +91 and spaces", () => {
    const r = parseTestNumbers("9000000001\n+91 90000 00002, 919000000003;  9000000001")
    expect(r.numbers).toEqual(["9000000001", "9000000002", "9000000003"])
    expect(r.invalid).toEqual([])
  })
  it("flags anything that is not a 10-digit Indian mobile", () => {
    const r = parseTestNumbers("12345\n5000000000\n9000000001\nabc")
    expect(r.numbers).toEqual(["9000000001"])
    expect(r.invalid).toEqual(["12345", "5000000000", "abc"])
  })
  it("returns nothing for blank input", () => {
    expect(parseTestNumbers("  \n ")).toEqual({ numbers: [], invalid: [] })
  })
})
