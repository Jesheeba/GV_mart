import { describe, expect, it } from "vitest"
import { isReworkChargeable, isWithinReworkWindow, reworkPenalty, ticketCompletedAt } from "./rework"

const NOW = new Date("2026-11-26T12:00:00+05:30")
const daysAgo = (d: number) => new Date(NOW.getTime() - d * 86_400_000).toISOString()

describe("AC1 rework window (settings.rework_window_days)", () => {
  it("allows a job finished inside the window", () => expect(isWithinReworkWindow(daysAgo(29), 30, NOW)).toBe(true))
  it("allows the last day of the window", () => expect(isWithinReworkWindow(daysAgo(30), 30, NOW)).toBe(true))
  it("refuses a job finished after the window", () => expect(isWithinReworkWindow(daysAgo(31), 30, NOW)).toBe(false))
  it("honours a master-raised window", () => expect(isWithinReworkWindow(daysAgo(45), 60, NOW)).toBe(true))
  it("refuses missing or invalid dates", () => {
    expect(isWithinReworkWindow(null, 30, NOW)).toBe(false)
    expect(isWithinReworkWindow("not a date", 30, NOW)).toBe(false)
  })
})

describe("AC5 rework penalty (P2: every rework after the Xth costs Y)", () => {
  it("is 0 when the master has not set X or Y", () => {
    expect(reworkPenalty(12, null, 200)).toBe(0)
    expect(reworkPenalty(12, 10, null)).toBe(0)
  })
  it("is 0 up to and including X", () => {
    expect(reworkPenalty(0, 10, 200)).toBe(0)
    expect(reworkPenalty(10, 10, 200)).toBe(0)
  })
  it("charges Y for each rework after X", () => {
    expect(reworkPenalty(11, 10, 200)).toBe(200)
    expect(reworkPenalty(13, 10, 200)).toBe(600)
  })
  it("X = 0 charges every rework", () => expect(reworkPenalty(4, 0, 200)).toBe(800))
})

describe("AC4/AC5 on-site choice", () => {
  it("free rework is not chargeable", () => expect(isReworkChargeable("free")).toBe(false))
  it("paid is chargeable", () => expect(isReworkChargeable("paid")).toBe(true))
  it("no choice yet is not chargeable", () => expect(isReworkChargeable(null)).toBe(false))
})

describe("ticketCompletedAt (UI window check)", () => {
  it("uses the latest finished visit", () => {
    expect(
      ticketCompletedAt({ updated_at: "2026-11-01T00:00:00Z", service_visits: [{ timer_end: "2026-11-20T10:00:00Z" }, { timer_end: "2026-11-21T10:00:00Z" }, { timer_end: null }] })
    ).toBe("2026-11-21T10:00:00Z")
  })
  it("falls back to updated_at when no visit finished", () => {
    expect(ticketCompletedAt({ updated_at: "2026-11-01T00:00:00Z", service_visits: [] })).toBe("2026-11-01T00:00:00Z")
  })
})
