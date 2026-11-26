import { describe, expect, it } from "vitest"
import { findByLabel, normalizeLabel, quickAddText } from "./quickAdd"

describe("quick-add AC: offer '+ Add' only for a genuinely new name", () => {
  it("new name is offered, normalised like the RPC (trim + collapse spaces)", () => {
    expect(quickAddText("  Low   water flow ", ["Not cooling"])).toBe("Low water flow")
  })
  it("exact existing label (any case/spacing) is not offered — duplicate never inserted", () => {
    expect(quickAddText("low  WATER flow", ["Low water flow"])).toBeNull()
  })
  it("a prefix of an existing label is still offered (it is a different name)", () => {
    expect(quickAddText("Low water", ["Low water flow"])).toBe("Low water")
  })
})

describe("quick-add edge cases", () => {
  it("blank / whitespace-only → not offered", () => {
    expect(quickAddText("", [])).toBeNull()
    expect(quickAddText("   ", [])).toBeNull()
  })
  it("over max length (120, matches RPC check) → not offered; exactly 120 → offered", () => {
    expect(quickAddText("a".repeat(121), [])).toBeNull()
    expect(quickAddText("a".repeat(120), [])).toBe("a".repeat(120))
  })
  it("normalizeLabel collapses tabs/newlines", () => {
    expect(normalizeLabel("\tLeak\n at  tap ")).toBe("Leak at tap")
  })
})

describe("quick-add F3b: findByLabel picks an existing entry instead of a duplicate", () => {
  const suppliers = [{ id: "1", name: "Aqua Traders" }, { id: "2", name: "Kent Distributor" }]
  it("matches ignoring case and extra spaces", () => {
    expect(findByLabel(suppliers, (s) => s.name, "  aqua   TRADERS ")?.id).toBe("1")
  })
  it("no match → undefined (caller creates a new one)", () => {
    expect(findByLabel(suppliers, (s) => s.name, "Aqua")).toBeUndefined()
  })
})
