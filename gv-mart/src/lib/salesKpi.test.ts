import { describe, expect, it } from "vitest"
import { averageTicket, currentIstMonth, isMonthString, monthRange, previousDay } from "./salesKpi"

describe("currentIstMonth", () => {
  it("takes the month from the IST date it is given", () => {
    expect(currentIstMonth({ date: "2026-10-13" })).toBe("2026-10")
  })
})

describe("monthRange", () => {
  it("covers the whole calendar month", () => {
    expect(monthRange("2026-10")).toEqual({ from: "2026-10-01", to: "2026-10-31" })
    expect(monthRange("2026-11")).toEqual({ from: "2026-11-01", to: "2026-11-30" })
  })
  it("handles February in a leap and a non-leap year, and December", () => {
    expect(monthRange("2028-02").to).toBe("2028-02-29")
    expect(monthRange("2026-02").to).toBe("2026-02-28")
    expect(monthRange("2026-12").to).toBe("2026-12-31")
  })
  it("rejects a malformed month", () => {
    expect(() => monthRange("2026-13")).toThrow()
    expect(() => monthRange("")).toThrow()
    expect(isMonthString("2026-1")).toBe(false)
    expect(isMonthString("2026-01")).toBe(true)
  })
})

describe("previousDay", () => {
  it("crosses month and year boundaries", () => {
    expect(previousDay("2026-10-01")).toBe("2026-09-30")
    expect(previousDay("2027-01-01")).toBe("2026-12-31")
    expect(previousDay("2028-03-01")).toBe("2028-02-29")
  })
})

describe("averageTicket", () => {
  it("is total over invoice count, rounded to paise", () => {
    expect(averageTicket(17110, 2)).toBe(8555)
    expect(averageTicket(17228, 3)).toBe(5742.67)
  })
  it("is null with no invoices (never 0, never NaN)", () => {
    expect(averageTicket(0, 0)).toBeNull()
  })
})
