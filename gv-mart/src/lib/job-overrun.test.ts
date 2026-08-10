import { describe, expect, it } from "vitest"
import { computeJobOverrun } from "./job-overrun"

const NOW = new Date("2026-07-23T10:00:00.000Z")
const MIN_MS = 60_000

function minutesAgoIso(minutes: number) {
  return new Date(NOW.getTime() - minutes * MIN_MS).toISOString()
}

describe("computeJobOverrun", () => {
  it("is not overrun when no visit has started (timerStart null)", () => {
    expect(computeJobOverrun({ timerStart: null, timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())).toEqual({
      isOverrun: false,
      elapsedMinutes: null,
      overrunByMinutes: null,
    })
  })

  it("is not overrun once the visit is closed, no matter how long it ran", () => {
    const result = computeJobOverrun(
      { timerStart: minutesAgoIso(120), timerEnd: minutesAgoIso(5), estimatedDurationMinutes: 30 },
      NOW.getTime()
    )
    expect(result.isOverrun).toBe(false)
    expect(result.elapsedMinutes).toBeNull()
  })

  it("is not overrun when no estimate is set (the real, currently-unfilled gap — never renders as red)", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(999), timerEnd: null, estimatedDurationMinutes: null }, NOW.getTime())
    expect(result.isOverrun).toBe(false)
    expect(result.overrunByMinutes).toBeNull()
  })

  it("treats a zero or negative estimate as unset rather than an instant overrun", () => {
    expect(computeJobOverrun({ timerStart: minutesAgoIso(5), timerEnd: null, estimatedDurationMinutes: 0 }, NOW.getTime()).isOverrun).toBe(false)
    expect(computeJobOverrun({ timerStart: minutesAgoIso(5), timerEnd: null, estimatedDurationMinutes: -10 }, NOW.getTime()).isOverrun).toBe(false)
  })

  it("is not overrun while elapsed time is still within the estimate", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(20), timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())
    expect(result.isOverrun).toBe(false)
    expect(result.elapsedMinutes).toBeCloseTo(20, 5)
  })

  it("is not overrun exactly at the estimate boundary", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(30), timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())
    expect(result.isOverrun).toBe(false)
  })

  it("is not overrun while still inside the 5-minute grace buffer past the estimate", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(34), timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())
    expect(result.isOverrun).toBe(false)
    expect(result.overrunByMinutes).toBeNull()
  })

  it("is not overrun exactly at the estimate + buffer boundary", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(35), timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())
    expect(result.isOverrun).toBe(false)
  })

  it("turns overrun the moment elapsed time passes the estimate plus the 5-minute buffer", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(36), timerEnd: null, estimatedDurationMinutes: 30 }, NOW.getTime())
    expect(result.isOverrun).toBe(true)
    expect(result.elapsedMinutes).toBeCloseTo(36, 5)
    expect(result.overrunByMinutes).toBeCloseTo(6, 5)
  })

  it("reports how far over the raw estimate (not the buffered threshold) a long-running visit is", () => {
    const result = computeJobOverrun({ timerStart: minutesAgoIso(90), timerEnd: null, estimatedDurationMinutes: 45 }, NOW.getTime())
    expect(result.isOverrun).toBe(true)
    expect(result.overrunByMinutes).toBeCloseTo(45, 5)
  })
})
