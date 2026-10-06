import { afterEach, describe, expect, it, vi } from "vitest"
import { addDaysIso, dateRangeForPreset, defaultDateRange, defaultPeriodValue, periodToRange } from "./reports"

// periodToRange used to build Dates from the device's own calendar. It is now plain string arithmetic,
// so a month / year / range must come out identically wherever the browser happens to be.
type Proc = { env: Record<string, string | undefined> }
const proc = (globalThis as unknown as { process: Proc }).process
const ZONES = ["Asia/Kolkata", "UTC", "America/Los_Angeles"] as const

describe.each(ZONES)("periodToRange in %s", (tz) => {
  const original = proc.env.TZ
  afterEach(() => {
    proc.env.TZ = original
  })

  it("month: first and last day, including February and a leap February", () => {
    proc.env.TZ = tz
    expect(periodToRange({ mode: "month", month: "2026-10" })).toEqual({ from: "2026-10-01", to: "2026-10-31" })
    expect(periodToRange({ mode: "month", month: "2026-02" })).toEqual({ from: "2026-02-01", to: "2026-02-28" })
    expect(periodToRange({ mode: "month", month: "2028-02" })).toEqual({ from: "2028-02-01", to: "2028-02-29" })
    expect(periodToRange({ mode: "month", month: "2026-12" })).toEqual({ from: "2026-12-01", to: "2026-12-31" })
    expect(periodToRange({ mode: "month", month: "2026-09" })).toEqual({ from: "2026-09-01", to: "2026-09-30" })
  })

  it("year: January 1 to December 31", () => {
    proc.env.TZ = tz
    expect(periodToRange({ mode: "year", year: 2026 })).toEqual({ from: "2026-01-01", to: "2026-12-31" })
  })

  it("range: passed through untouched", () => {
    proc.env.TZ = tz
    const range = { from: "2026-10-05", to: "2026-10-09" }
    expect(periodToRange({ mode: "range", range })).toBe(range)
  })
})

describe("IST-anchored defaults", () => {
  afterEach(() => vi.useRealTimers())

  it("'today' is the IST date even when the UTC date is still the day before (00:30 IST Nov 1 = Oct 31 UTC)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-10-31T19:00:00Z"))
    expect(defaultPeriodValue()).toEqual({ mode: "month", month: "2026-11" })
    expect(defaultDateRange(30)).toEqual({ from: "2026-10-02", to: "2026-11-01" })
    expect(dateRangeForPreset("thisMonth")).toEqual({ from: "2026-11-01", to: "2026-11-01" })
  })

  it("presets derive from the given day with pure date arithmetic", () => {
    expect(dateRangeForPreset("thisMonth", "2026-10-06")).toEqual({ from: "2026-10-01", to: "2026-10-06" })
    expect(dateRangeForPreset("previousMonth", "2026-10-06")).toEqual({ from: "2026-09-01", to: "2026-09-30" })
    expect(dateRangeForPreset("previousMonth", "2026-01-15")).toEqual({ from: "2025-12-01", to: "2025-12-31" })
    expect(dateRangeForPreset("previousMonth", "2028-03-10")).toEqual({ from: "2028-02-01", to: "2028-02-29" })
    expect(dateRangeForPreset("thisYear", "2026-10-06")).toEqual({ from: "2026-01-01", to: "2026-10-06" })
    expect(dateRangeForPreset("allTime", "2026-10-06")).toEqual({ from: "2000-01-01", to: "2026-10-06" })
  })

  it("addDaysIso crosses month and year ends", () => {
    expect(addDaysIso("2026-03-01", -1)).toBe("2026-02-28")
    expect(addDaysIso("2026-12-31", 1)).toBe("2027-01-01")
    expect(addDaysIso("2026-10-06", -30)).toBe("2026-09-06")
  })
})
