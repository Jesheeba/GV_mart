import { describe, expect, it } from "vitest"
import { fitsJob, isBookableDate, isNarrowWindow, largestFreeWindow } from "./booking-window"

const WORK_START = "09:00"
const WORK_END = "19:00"

describe("largestFreeWindow", () => {
  it("returns the full working window when nothing is blocked", () => {
    expect(largestFreeWindow(WORK_START, WORK_END, [])).toEqual({ availableFrom: "09:00", availableTo: "19:00", minutes: 600 })
  })

  it("picks the largest remaining gap when one window is blocked mid-day", () => {
    // blocked 13:00-14:00 -> gaps are 09:00-13:00 (240m) and 14:00-19:00 (300m); largest wins
    const result = largestFreeWindow(WORK_START, WORK_END, [{ start: "13:00", end: "14:00" }])
    expect(result).toEqual({ availableFrom: "14:00", availableTo: "19:00", minutes: 300 })
  })

  it("merges overlapping/adjacent blocked windows before finding the gap", () => {
    const result = largestFreeWindow(WORK_START, WORK_END, [
      { start: "10:00", end: "11:30" },
      { start: "11:00", end: "12:00" }, // overlaps the first -> merges into 10:00-12:00
    ])
    // gaps: 09:00-10:00 (60m), 12:00-19:00 (420m) -> largest wins
    expect(result).toEqual({ availableFrom: "12:00", availableTo: "19:00", minutes: 420 })
  })

  it("clips a blocked window that spills outside working hours", () => {
    const result = largestFreeWindow(WORK_START, WORK_END, [{ start: "07:00", end: "10:00" }])
    expect(result).toEqual({ availableFrom: "10:00", availableTo: "19:00", minutes: 540 })
  })

  it("returns null/0 when the whole day is blocked", () => {
    const result = largestFreeWindow(WORK_START, WORK_END, [{ start: "00:00", end: "23:59" }])
    expect(result).toEqual({ availableFrom: null, availableTo: null, minutes: 0 })
  })

  it("ties go to the earliest-starting gap", () => {
    // work 09:00-15:00, block the middle two hours -> two equal 120m gaps
    // (09:00-11:00 and 13:00-15:00); earliest-starting one wins the tie.
    const result = largestFreeWindow("09:00", "15:00", [{ start: "11:00", end: "13:00" }])
    expect(result).toEqual({ availableFrom: "09:00", availableTo: "11:00", minutes: 120 })
  })
})

describe("isNarrowWindow", () => {
  it("is narrow when minutes <= threshold", () => {
    expect(isNarrowWindow({ availableFrom: "13:00", availableTo: "14:00", minutes: 60 }, 90)).toBe(true)
    expect(isNarrowWindow({ availableFrom: "13:00", availableTo: "14:30", minutes: 90 }, 90)).toBe(true)
  })

  it("is not narrow above the threshold", () => {
    expect(isNarrowWindow({ availableFrom: "09:00", availableTo: "19:00", minutes: 600 }, 90)).toBe(false)
  })

  it("a fully blocked day (null) is never 'narrow' — it's simply not bookable", () => {
    expect(isNarrowWindow({ availableFrom: null, availableTo: null, minutes: 0 }, 90)).toBe(false)
  })
})

describe("fitsJob / isBookableDate", () => {
  it("a narrow window that's shorter than the job's own duration does not fit", () => {
    const narrow = { availableFrom: "13:00", availableTo: "13:20", minutes: 20 }
    expect(fitsJob(narrow, 45)).toBe(false)
    expect(isBookableDate(narrow, 90, 45)).toBe(false)
  })

  it("a narrow window that's still long enough for the job is bookable", () => {
    const narrow = { availableFrom: "13:00", availableTo: "13:50", minutes: 50 }
    expect(fitsJob(narrow, 45)).toBe(true)
    expect(isBookableDate(narrow, 90, 45)).toBe(true)
  })

  it("a wide (non-narrow) window is always bookable regardless of job duration", () => {
    const wide = { availableFrom: "09:00", availableTo: "19:00", minutes: 600 }
    expect(isBookableDate(wide, 90, 10_000)).toBe(true)
  })

  it("a fully blocked day is never bookable", () => {
    expect(isBookableDate({ availableFrom: null, availableTo: null, minutes: 0 }, 90, 10)).toBe(false)
  })
})
