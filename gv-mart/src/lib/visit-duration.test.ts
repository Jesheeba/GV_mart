import { describe, expect, it } from "vitest"
import { formatDurationMinutes, minutesBetween, resolveVisitDurationMinutes } from "./visit-duration"

describe("minutesBetween", () => {
  it("returns null when either timestamp is missing", () => {
    expect(minutesBetween(null, "2026-01-01T00:10:00Z")).toBeNull()
    expect(minutesBetween("2026-01-01T00:00:00Z", null)).toBeNull()
  })

  it("computes the rounded minute difference", () => {
    expect(minutesBetween("2026-01-01T00:00:00Z", "2026-01-01T00:10:30Z")).toBe(11)
  })

  it("never returns negative even if end precedes start", () => {
    expect(minutesBetween("2026-01-01T00:10:00Z", "2026-01-01T00:00:00Z")).toBe(0)
  })
})

describe("resolveVisitDurationMinutes", () => {
  it("prefers the persisted actual_duration_minutes over live computation", () => {
    const visit = { timer_start: "2026-01-01T00:00:00Z", timer_end: "2026-01-01T01:00:00Z", actual_duration_minutes: 45 }
    expect(resolveVisitDurationMinutes(visit)).toBe(45)
  })

  it("falls back to live computation when actual_duration_minutes is null (pre-migration row)", () => {
    const visit = { timer_start: "2026-01-01T00:00:00Z", timer_end: "2026-01-01T00:20:00Z", actual_duration_minutes: null }
    expect(resolveVisitDurationMinutes(visit)).toBe(20)
  })

  it("returns null for a null/undefined visit", () => {
    expect(resolveVisitDurationMinutes(null)).toBeNull()
    expect(resolveVisitDurationMinutes(undefined)).toBeNull()
  })
})

describe("formatDurationMinutes", () => {
  it("formats under an hour as just minutes", () => {
    expect(formatDurationMinutes(45)).toBe("45m")
  })

  it("formats an hour or more as hours + minutes", () => {
    expect(formatDurationMinutes(92)).toBe("1h 32m")
  })

  it("formats an exact hour with 0 minutes", () => {
    expect(formatDurationMinutes(120)).toBe("2h 0m")
  })
})
