import { describe, expect, it } from "vitest"
import { isAmcRenewalOpen } from "./amc-window"

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
