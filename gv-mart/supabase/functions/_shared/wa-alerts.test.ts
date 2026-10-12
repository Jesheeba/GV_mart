import { describe, expect, it } from "vitest"
import { DEFAULT_SKIPPED_ALERT_THRESHOLD, STUCK_PENDING_MS, istDayStartIso, normaliseThreshold, skippedAlertDue, stuckAlertDue, stuckBeforeIso } from "./wa-alerts"

describe("stuck pending rows", () => {
  it("the threshold is 15 minutes", () => {
    expect(STUCK_PENDING_MS).toBe(15 * 60_000)
    const now = Date.parse("2026-10-16T10:00:00Z")
    expect(stuckBeforeIso(now)).toBe("2026-10-16T09:45:00.000Z")
  })
  it("alerts on any stuck row, never on zero", () => {
    expect(stuckAlertDue(0)).toBe(false)
    expect(stuckAlertDue(1)).toBe(true)
  })
})

describe("skipped_no_template threshold", () => {
  it("defaults to 10 per day and alerts only ABOVE the threshold", () => {
    expect(DEFAULT_SKIPPED_ALERT_THRESHOLD).toBe(10)
    expect(skippedAlertDue(10, null)).toBe(false)
    expect(skippedAlertDue(11, null)).toBe(true)
    expect(skippedAlertDue(11, undefined)).toBe(true)
  })
  it("uses the master's value; 0 switches the alert off; garbage falls back to the default", () => {
    expect(skippedAlertDue(3, 2)).toBe(true)
    expect(skippedAlertDue(2, 2)).toBe(false)
    expect(skippedAlertDue(500, 0)).toBe(false)
    expect(normaliseThreshold(-4)).toBe(10)
    expect(normaliseThreshold(Number.NaN)).toBe(10)
    expect(normaliseThreshold(7.9)).toBe(7)
  })
})

describe("IST day boundary", () => {
  it("2026-10-16 23:59 IST belongs to the 16th, 00:00 IST starts the 17th", () => {
    expect(istDayStartIso(Date.parse("2026-10-16T18:29:00Z"))).toBe("2026-10-15T18:30:00.000Z") // 23:59 IST on the 16th
    expect(istDayStartIso(Date.parse("2026-10-16T18:30:00Z"))).toBe("2026-10-16T18:30:00.000Z") // 00:00 IST on the 17th
  })
})
