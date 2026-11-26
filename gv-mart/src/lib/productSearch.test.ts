import { describe, expect, it } from "vitest"
import { matchesAllWords, productExtraParts, productMatchesQuery, productSearchLabel } from "./productSearch"

// Real rows from the 2026-11-03 spreadsheet import (live DB, read 2026-11-26).
const imported = (model: string, name: string) => ({ name, brands: { name: "RO (spreadsheet import)" }, models: { name: model } })
const rop2090Blue = imported("2090 BLUE", "ROP 2090 BLUE")
const ropRomaBlue = imported("ROMA BLUE", "ROP ROMA BLUE")
const ropDolphin = imported("DOLPHIN", "ROP DOLPHIN")
const kent = { name: "Grand Plus RO", brands: { name: "Kent" }, models: { name: "Grand" } }

const spares = ["ROS ADAPTER ACCORD 24V SMBS 2.5A", "ROS ADAPTER ACCORD 24V SMPS", "ROS ADAPTER ACCORD 36V SMPS", 'ROS ALKALINE FILTER 10"', "ROS BODY CONNECTOR H1/4"]

describe("picker-search A1: multi-word spare search", () => {
  it("'ros adapter 24v' finds both 24V adapters only", () => {
    expect(spares.filter((s) => matchesAllWords(s, "ros adapter 24v"))).toEqual(["ROS ADAPTER ACCORD 24V SMBS 2.5A", "ROS ADAPTER ACCORD 24V SMPS"])
  })
  it("words match in any order", () => {
    expect(spares.filter((s) => matchesAllWords(s, "smps 36v"))).toEqual(["ROS ADAPTER ACCORD 36V SMPS"])
  })
  it("punctuation in names is searchable (10\", H1/4)", () => {
    expect(spares.filter((s) => matchesAllWords(s, 'filter 10"'))).toEqual(['ROS ALKALINE FILTER 10"'])
    expect(spares.filter((s) => matchesAllWords(s, "h1/4"))).toEqual(["ROS BODY CONNECTOR H1/4"])
  })
})

describe("picker-search A2: multi-word product search", () => {
  it("'rop blue' finds both blue products, skipping the words in between", () => {
    expect([rop2090Blue, ropRomaBlue, ropDolphin].filter((p) => productMatchesQuery(p, "rop blue"))).toEqual([rop2090Blue, ropRomaBlue])
  })
  it("brand name still surfaces its products", () => {
    expect(productMatchesQuery(kent, "kent")).toBe(true)
  })
  it("no match returns false", () => {
    expect(productMatchesQuery(ropDolphin, "kent")).toBe(false)
  })
})

describe("picker-search edge cases: query whitespace and case", () => {
  it("empty / whitespace-only query matches everything", () => {
    expect(matchesAllWords("anything", "")).toBe(true)
    expect(matchesAllWords("anything", "   \t ")).toBe(true)
  })
  it("A5: spaces between words (single, double, leading, trailing) never block a match", () => {
    expect(matchesAllWords("ROS ANTI SCALE BALL", " anti  scale ")).toBe(true)
  })
  it("case-insensitive", () => {
    expect(matchesAllWords("ROS ANTI SCALE BALL", "Anti BALL")).toBe(true)
  })
})

describe("picker-search A3/A4: product labels", () => {
  it("A3: spreadsheet-import product shows its name once, without the placeholder brand", () => {
    expect(productSearchLabel(rop2090Blue)).toBe("ROP 2090 BLUE")
  })
  it("A4: real brand/model still shown before the name", () => {
    expect(productSearchLabel({ name: "RO Purifier", brands: { name: "Kent" }, models: { name: "Grand" } })).toBe("Kent Grand — RO Purifier")
  })
  it("model already inside the product name is not repeated, brand kept", () => {
    expect(productSearchLabel(kent)).toBe("Kent — Grand Plus RO")
  })
  it("no brand/model → just the name", () => {
    expect(productSearchLabel({ name: "Loose item" })).toBe("Loose item")
  })
})

describe("picker-search A3: cart card subtitle (productExtraParts)", () => {
  it("spreadsheet-import line shows no brand/model (only category is added by the card)", () => {
    expect(productExtraParts("ROP 2090 BLUE", "RO (spreadsheet import)", "2090 BLUE")).toEqual([])
  })
  it("real brand/model kept; '—' fillers dropped", () => {
    expect(productExtraParts("RO Purifier", "Kent", "Grand")).toEqual(["Kent", "Grand"])
    expect(productExtraParts("Loose item", "—", "—")).toEqual([])
  })
})
