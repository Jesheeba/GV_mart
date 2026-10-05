import { describe, expect, it } from "vitest"
import {
  addDays,
  addMonths,
  defaultNextFor,
  formatIstDateTime,
  isFutureIst,
  isoDow,
  istDate,
  istTime,
  laterTodaySlot,
  nextWorkingDay,
  resolveDateChip,
  suggestWorkingDay,
  telHref,
  toIso,
} from "./lead-followups"

describe("IST date arithmetic", () => {
  it("adds days across month and year boundaries", () => {
    expect(addDays("2026-10-31", 1)).toBe("2026-11-01")
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01")
    expect(addDays("2026-10-05", 14)).toBe("2026-10-19")
  })
  it("adds months, clamping to month end", () => {
    expect(addMonths("2026-01-31", 1)).toBe("2026-02-28")
    expect(addMonths("2026-10-05", 3)).toBe("2027-01-05")
    expect(addMonths("2026-11-30", 3)).toBe("2027-02-28")
  })
  it("ISO weekday: Monday 1 … Sunday 7", () => {
    expect(isoDow("2026-10-05")).toBe(1) // Monday
    expect(isoDow("2026-10-10")).toBe(6) // Saturday
    expect(isoDow("2026-10-11")).toBe(7) // Sunday
  })
})

describe("working days (Mon–Sat)", () => {
  it("skips Sunday", () => {
    expect(nextWorkingDay("2026-10-10")).toBe("2026-10-12") // Sat -> Mon
    expect(nextWorkingDay("2026-10-11")).toBe("2026-10-12") // Sun -> Mon
    expect(nextWorkingDay("2026-10-09")).toBe("2026-10-10") // Fri -> Sat
  })
  it("suggests the next working day only for a non-working day", () => {
    expect(suggestWorkingDay("2026-10-11")).toBe("2026-10-12")
    expect(suggestWorkingDay("2026-10-12")).toBeNull()
  })
  it("honours a custom schedule (Mon–Fri)", () => {
    expect(nextWorkingDay("2026-10-09", [1, 2, 3, 4, 5])).toBe("2026-10-12")
    expect(suggestWorkingDay("2026-10-10", [1, 2, 3, 4, 5])).toBe("2026-10-12")
  })
})

describe("instants are IST regardless of device timezone", () => {
  it("toIso converts IST wall-clock to UTC", () => {
    expect(toIso("2026-10-07", "00:30")).toBe("2026-10-06T19:00:00.000Z")
    expect(toIso("2026-10-06", "10:00")).toBe("2026-10-06T04:30:00.000Z")
  })
  it("istDate/istTime read the IST day and time of an instant", () => {
    expect(istDate("2026-10-06T19:00:00.000Z")).toBe("2026-10-07")
    expect(istTime("2026-10-06T19:00:00.000Z")).toBe("00:30")
    expect(istDate("2026-10-06T18:29:59.000Z")).toBe("2026-10-06")
  })
  it("isFutureIst compares against the supplied now", () => {
    const now = new Date("2026-10-06T04:30:00.000Z") // 10:00 IST
    expect(isFutureIst("2026-10-06", "10:01", now)).toBe(true)
    expect(isFutureIst("2026-10-06", "09:59", now)).toBe(false)
  })
  it("formats in IST", () => {
    expect(formatIstDateTime("2026-10-06T04:30:00.000Z")).toMatch(/Tue.*6.*Oct.*10:00/i)
  })
})

describe("chips", () => {
  const now = { date: "2026-10-05", time: "11:00" } // Monday
  it("resolves the date chips from IST today", () => {
    expect(resolveDateChip("tomorrow", now)).toEqual({ date: "2026-10-06" })
    expect(resolveDateChip("days3", now)).toEqual({ date: "2026-10-08" })
    expect(resolveDateChip("week1", now)).toEqual({ date: "2026-10-12" })
    expect(resolveDateChip("weeks2", now)).toEqual({ date: "2026-10-19" })
    expect(resolveDateChip("month1", now)).toEqual({ date: "2026-11-05" })
    expect(resolveDateChip("months3", now)).toEqual({ date: "2027-01-05" })
    expect(resolveDateChip("custom", now)).toBeNull()
  })
  it("later today picks the first slot at least an hour away", () => {
    expect(laterTodaySlot("11:00")).toBe("14:00")
    expect(laterTodaySlot("13:30")).toBe("17:00")
    expect(laterTodaySlot("16:30")).toBe("18:30")
    expect(laterTodaySlot("17:45")).toBeNull()
    expect(resolveDateChip("laterToday", { date: "2026-10-05", time: "11:00" })).toEqual({ date: "2026-10-05", time: "14:00" })
    expect(resolveDateChip("laterToday", { date: "2026-10-05", time: "18:30" })).toBeNull()
  })
})

describe("defaultNextFor (outcome defaults)", () => {
  const monday = { date: "2026-10-05", time: "11:00" }
  it("today -> a later-today slot", () => {
    expect(defaultNextFor({ followup_mode: "offset", default_offset_days: 0 }, monday)).toEqual({ date: "2026-10-05", time: "14:00", exact: false })
  })
  it("today after closing rolls to the next working day at 10:00", () => {
    expect(defaultNextFor({ followup_mode: "offset", default_offset_days: 0 }, { date: "2026-10-10", time: "18:45" })).toEqual({
      date: "2026-10-12",
      time: "10:00",
      exact: false,
    })
  })
  it("N days -> that date at 10:00", () => {
    expect(defaultNextFor({ followup_mode: "offset", default_offset_days: 2 }, monday)).toEqual({ date: "2026-10-07", time: "10:00", exact: false })
  })
  it("ask_date has no default date; exact_time wants a time", () => {
    expect(defaultNextFor({ followup_mode: "ask_date", default_offset_days: null }, monday).date).toBeNull()
    expect(defaultNextFor({ followup_mode: "exact_time", default_offset_days: 0 }, monday)).toEqual({ date: "2026-10-05", time: null, exact: true })
    expect(defaultNextFor({ followup_mode: "none", default_offset_days: null }, monday).date).toBeNull()
  })
})

describe("contact links", () => {
  it("builds a tel: href", () => {
    expect(telHref("98840 11001")).toBe("tel:9884011001")
    expect(telHref("+91 98840-11001")).toBe("tel:+919884011001")
  })
})
