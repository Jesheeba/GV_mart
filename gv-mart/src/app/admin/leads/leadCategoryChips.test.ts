import { describe, expect, it } from "vitest"
import { orderedCategoryChips } from "./leadCategoryChips"

describe("orderedCategoryChips", () => {
  it("orders chips Service -> Product -> Spare -> AMC regardless of input order", () => {
    expect(orderedCategoryChips([{ key: "amc" }, { key: "service" }, { key: "spare" }, { key: "product" }])).toEqual(["service", "product", "spare", "amc"])
  })

  it("drops a category with no active kind", () => {
    expect(orderedCategoryChips([{ key: "service" }, { key: "product" }])).toEqual(["service", "product"])
  })

  it("returns an empty list when nothing is active", () => {
    expect(orderedCategoryChips([])).toEqual([])
  })

  it("ignores keys outside the known four categories", () => {
    expect(orderedCategoryChips([{ key: "warranty" }, { key: "spare" }])).toEqual(["spare"])
  })
})
