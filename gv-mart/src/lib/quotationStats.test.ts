import { describe, expect, it } from "vitest"
import { quotationStats } from "./quotationStats"

const rows = (open: number, converted: number, lost: number) => [
  ...Array.from({ length: open }, () => ({ status: "open" })),
  ...Array.from({ length: converted }, () => ({ status: "converted" })),
  ...Array.from({ length: lost }, () => ({ status: "lost" })),
]

describe("quotationStats (Quotations KPI corner %, 2026-11-27)", () => {
  it("screenshot case: 4 open, 0 converted, 1 lost → 80% / 0% / 20%, rate 0% of 1 decided", () => {
    expect(quotationStats(rows(4, 0, 1))).toEqual({ open: 4, converted: 0, lost: 1, openPct: 80, convertedPct: 0, lostPct: 20, decided: 1, rate: 0 })
  })
  it("conversion rate counts only decided quotes", () => {
    const s = quotationStats(rows(10, 3, 1))
    expect(s.rate).toBe(75)
    expect(s.convertedPct).toBe(21)
  })
  it("no quotations → all zero, no divide-by-zero", () => {
    expect(quotationStats([])).toEqual({ open: 0, converted: 0, lost: 0, openPct: 0, convertedPct: 0, lostPct: 0, decided: 0, rate: 0 })
  })
})
