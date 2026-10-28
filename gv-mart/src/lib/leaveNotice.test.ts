import { describe, expect, it } from "vitest"
import { daysBetween, isInAdvance } from "./leaveNotice"

describe("isInAdvance (notice rule preview)", () => {
  it("requested exactly leave_notice_days before the start counts as in advance (inclusive boundary)", () => {
    expect(isInAdvance("2026-03-01T04:30:00Z", "2026-03-04", 3)).toBe(true)
  })
  it("requested one day short of the notice window counts as late", () => {
    expect(isInAdvance("2026-03-02T04:30:00Z", "2026-03-04", 3)).toBe(false)
  })
  it("requested well in advance counts as in advance", () => {
    expect(isInAdvance("2026-02-01T04:30:00Z", "2026-03-10", 3)).toBe(true)
  })
  it("requested exactly one day before the start (notice=1, the default) is still in advance", () => {
    expect(isInAdvance("2026-03-09T18:00:00Z", "2026-03-10", 1)).toBe(true)
  })
  it("requested the same day as the start (notice=1) is late", () => {
    expect(isInAdvance("2026-03-10T04:00:00Z", "2026-03-10", 1)).toBe(false)
  })
})

describe("daysBetween", () => {
  it("same start and end date is a 1-day request", () => {
    expect(daysBetween("2026-03-10", "2026-03-10")).toBe(1)
  })
  it("a 30-day request spans start to start+29", () => {
    expect(daysBetween("2026-03-01", "2026-03-30")).toBe(30)
  })
})
