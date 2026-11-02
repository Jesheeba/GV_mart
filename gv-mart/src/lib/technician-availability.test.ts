import { describe, expect, it } from "vitest"
import { largestFreeWindow } from "./booking-window"
import { allFreeGaps, isOverlapping, isSlotFree, type TechnicianAvailabilityRow } from "./technician-availability"

describe("isOverlapping (mirrors _appt_range / appointments_technician_no_overlap's tstzrange('[)') && test)", () => {
  it("flags two ranges that genuinely overlap", () => {
    expect(isOverlapping("09:00", "10:00", "09:30", "10:30")).toBe(true)
    expect(isOverlapping("09:30", "10:30", "09:00", "10:00")).toBe(true)
  })

  it("flags one range fully containing the other", () => {
    expect(isOverlapping("09:00", "12:00", "10:00", "11:00")).toBe(true)
  })

  it("boundary adjacency: an appointment ending exactly when the next starts does NOT overlap (half-open '[)')", () => {
    expect(isOverlapping("09:00", "10:00", "10:00", "11:00")).toBe(false)
    expect(isOverlapping("10:00", "11:00", "09:00", "10:00")).toBe(false)
  })

  it("does not flag two genuinely separate ranges", () => {
    expect(isOverlapping("09:00", "10:00", "11:00", "12:00")).toBe(false)
  })

  it("works the same way on full ISO datetimes, not just HH:MM", () => {
    expect(isOverlapping("2026-11-10T09:00:00+05:30", "2026-11-10T10:00:00+05:30", "2026-11-10T10:00:00+05:30", "2026-11-10T11:00:00+05:30")).toBe(
      false
    )
    expect(isOverlapping("2026-11-10T09:00:00+05:30", "2026-11-10T10:30:00+05:30", "2026-11-10T10:00:00+05:30", "2026-11-10T11:00:00+05:30")).toBe(
      true
    )
  })
})

describe("allFreeGaps (mirrors _free_gaps, which mirrors the live _largest_free_window's merge algorithm)", () => {
  const WORK_START = "09:00"
  const WORK_END = "19:00"

  it("returns the whole day as one gap when nothing is busy", () => {
    expect(allFreeGaps(WORK_START, WORK_END, [])).toEqual([{ start: "09:00", end: "19:00", minutes: 600 }])
  })

  it("returns every gap around a mid-day busy window, not only the largest", () => {
    const gaps = allFreeGaps(WORK_START, WORK_END, [{ start: "13:00", end: "14:00" }])
    expect(gaps).toEqual([
      { start: "09:00", end: "13:00", minutes: 240 },
      { start: "14:00", end: "19:00", minutes: 300 },
    ])
  })

  it("merges overlapping/adjacent busy windows before computing gaps", () => {
    const gaps = allFreeGaps(WORK_START, WORK_END, [
      { start: "10:00", end: "11:30" },
      { start: "11:00", end: "12:00" },
      { start: "12:00", end: "12:30" }, // adjacent to the merged block -> still one block
    ])
    expect(gaps).toEqual([
      { start: "09:00", end: "10:00", minutes: 60 },
      { start: "12:30", end: "19:00", minutes: 390 },
    ])
  })

  it("is empty when the whole day is busy", () => {
    expect(allFreeGaps(WORK_START, WORK_END, [{ start: "00:00", end: "23:59" }])).toEqual([])
  })

  it("its largest gap always agrees with largestFreeWindow — same underlying merge, no divergent logic", () => {
    const blocked = [{ start: "10:00", end: "11:00" }, { start: "15:00", end: "16:30" }]
    const gaps = allFreeGaps(WORK_START, WORK_END, blocked)
    const biggest = gaps.reduce((a, b) => (b.minutes > a.minutes ? b : a))
    const single = largestFreeWindow(WORK_START, WORK_END, blocked)
    expect({ start: biggest.start, end: biggest.end, minutes: biggest.minutes }).toEqual({
      start: single.availableFrom,
      end: single.availableTo,
      minutes: single.minutes,
    })
  })
})

describe("isSlotFree / a technician on leave appears unavailable", () => {
  const freeRow: TechnicianAvailabilityRow = {
    technicianId: "tech-free",
    technicianName: "Free Tech",
    isOnLeave: false,
    workStart: "09:00",
    workEnd: "19:00",
    busyWindows: [],
    freeWindows: [{ start: "09:00", end: "19:00", minutes: 600 }],
  }

  const busyRow: TechnicianAvailabilityRow = {
    technicianId: "tech-busy",
    technicianName: "Busy Tech",
    isOnLeave: false,
    workStart: "09:00",
    workEnd: "19:00",
    busyWindows: [{ start: "09:00", end: "19:00" }],
    freeWindows: [],
  }

  it("a slot inside a free window is free", () => {
    expect(isSlotFree(freeRow, { start: "10:00", end: "11:00" })).toBe(true)
  })

  it("a slot with no covering free window is not free", () => {
    expect(isSlotFree(busyRow, { start: "10:00", end: "11:00" })).toBe(false)
  })

  it("a leave day is unavailable even if freeWindows were (incorrectly) non-empty — defence in depth", () => {
    const staleLeaveRow: TechnicianAvailabilityRow = { ...freeRow, isOnLeave: true }
    expect(isSlotFree(staleLeaveRow, { start: "10:00", end: "11:00" })).toBe(false)
  })

  it("two-technician scenario: one free, one busy at the same requested slot", () => {
    const slot = { start: "10:00", end: "11:00" }
    expect(isSlotFree(freeRow, slot)).toBe(true)
    expect(isSlotFree(busyRow, slot)).toBe(false)
  })
})
