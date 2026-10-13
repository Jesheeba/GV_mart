import { describe, expect, it } from "vitest"
import { amcPlanSummary, isAmcRenewalOpen, pricePerYearOf } from "./amc-window"

const NOW = new Date("2026-07-10T00:00:00.000Z")
const DAY_MS = 24 * 60 * 60 * 1000

function daysFromNow(days: number) {
  return new Date(NOW.getTime() + days * DAY_MS).toISOString()
}

describe("isAmcRenewalOpen", () => {
  it("is always open when there is no existing due date (nothing to renew yet)", () => {
    expect(isAmcRenewalOpen(null, 30, NOW)).toEqual({ withinWindow: true, daysUntil: null })
    expect(isAmcRenewalOpen(undefined, 30, NOW)).toEqual({ withinWindow: true, daysUntil: null })
  })

  it("is open on the due date itself", () => {
    const result = isAmcRenewalOpen(daysFromNow(0), 30, NOW)
    expect(result.daysUntil).toBe(0)
    expect(result.withinWindow).toBe(true)
  })

  it("is open exactly at the window boundary (daysUntil === windowDays)", () => {
    const result = isAmcRenewalOpen(daysFromNow(30), 30, NOW)
    expect(result.daysUntil).toBe(30)
    expect(result.withinWindow).toBe(true)
  })

  it("is closed just past the window boundary", () => {
    const result = isAmcRenewalOpen(daysFromNow(31), 30, NOW)
    expect(result.daysUntil).toBe(31)
    expect(result.withinWindow).toBe(false)
  })

  it("is open for an already-overdue due date", () => {
    const result = isAmcRenewalOpen(daysFromNow(-5), 30, NOW)
    expect(result.daysUntil).toBe(-5)
    expect(result.withinWindow).toBe(true)
  })

  it("rounds a partial day up before comparing to the window (Math.ceil)", () => {
    // 29.5 days out ceils to 30 -> still within a 30-day window...
    const withinThirty = isAmcRenewalOpen(daysFromNow(29.5), 30, NOW)
    expect(withinThirty.daysUntil).toBe(30)
    expect(withinThirty.withinWindow).toBe(true)
    // ...but past a 29-day window.
    const withinTwentyNine = isAmcRenewalOpen(daysFromNow(29.5), 29, NOW)
    expect(withinTwentyNine.withinWindow).toBe(false)
  })
})

describe("pricePerYearOf", () => {
  it("uses price_per_year directly when the column is populated", () => {
    // Build Order Step 1.1: a 3-year plan whose flat total is 9000 but whose
    // real per-year rate (e.g. a discounted multi-year bundle) is 2800/yr —
    // must NOT fall back to price/years (which would wrongly give 3000).
    expect(pricePerYearOf({ price: 9000, years: 3, price_per_year: 2800 })).toBe(2800)
  })

  it("falls back to price/years, rounded to paise, for legacy plans with no price_per_year", () => {
    expect(pricePerYearOf({ price: 9000, years: 3, price_per_year: null })).toBe(3000)
    expect(pricePerYearOf({ price: 9000, years: 3 })).toBe(3000)
    // 1000/3 = 333.333... -> rounds to 2 decimal places, not truncated/floored.
    expect(pricePerYearOf({ price: 1000, years: 3, price_per_year: undefined })).toBe(333.33)
  })

  it("treats price_per_year = 0 as a real (free) rate, not a missing value", () => {
    // Nullish coalescing, not `||` — a genuinely free promo year must not
    // silently fall back to the flat-total/years approximation.
    expect(pricePerYearOf({ price: 0, years: 1, price_per_year: 0 })).toBe(0)
  })

  it("never divides by zero for a malformed years value", () => {
    expect(pricePerYearOf({ price: 5000, years: 0, price_per_year: null })).toBe(5000)
  })
})

describe("amcPlanSummary", () => {
  it("3 years, 2 visits a year, started 13 Oct 2026: expires 13 Oct 2029 with 6 visits", () => {
    expect(amcPlanSummary({ years: 3, visits_per_year: 2 }, "2026-10-13")).toEqual({
      years: 3,
      visits: 6,
      expiryDate: "2029-10-13",
      expiryLabel: "13 Oct 2029",
    })
  })
  it("a 29 February start clamps to the last day of February in a non-leap year", () => {
    expect(amcPlanSummary({ years: 1, visits_per_year: 4 }, "2028-02-29").expiryDate).toBe("2029-02-28")
    expect(amcPlanSummary({ years: 4, visits_per_year: 1 }, "2028-02-29").expiryDate).toBe("2032-02-29")
  })
  it("no start date: counts still work, no expiry", () => {
    expect(amcPlanSummary({ years: 2, visits_per_year: 3 }, "")).toEqual({ years: 2, visits: 6, expiryDate: null, expiryLabel: null })
  })
})
