import { describe, expect, it } from "vitest"
import { parseStockLimits } from "./stockLimits"

describe("parseStockLimits (Spare form min/max stock for purchase orders)", () => {
  it("both empty → leave the stock row alone", () => {
    expect(parseStockLimits("", "  ")).toEqual({ kind: "none" })
  })
  it("valid pair → set", () => {
    expect(parseStockLimits("5", "20")).toEqual({ kind: "set", min: 5, max: 20 })
    expect(parseStockLimits("0", "0")).toEqual({ kind: "set", min: 0, max: 0 })
  })
  it("only one given → both required", () => {
    expect(parseStockLimits("5", "")).toEqual({ kind: "error", key: "masters.spares.stockLimitsBoth" })
    expect(parseStockLimits("", "20")).toEqual({ kind: "error", key: "masters.spares.stockLimitsBoth" })
  })
  it("negative, decimal or junk → whole numbers only", () => {
    expect(parseStockLimits("-1", "5")).toEqual({ kind: "error", key: "masters.spares.stockLimitsWhole" })
    expect(parseStockLimits("2.5", "5")).toEqual({ kind: "error", key: "masters.spares.stockLimitsWhole" })
    expect(parseStockLimits("abc", "5")).toEqual({ kind: "error", key: "masters.spares.stockLimitsWhole" })
  })
  it("max below min → refused (DB check inventory_max_stock_check)", () => {
    expect(parseStockLimits("10", "5")).toEqual({ kind: "error", key: "masters.spares.stockLimitsOrder" })
  })
})
