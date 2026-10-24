import { describe, expect, it } from "vitest"
import { formatDate, formatDateTime } from "./formatDate"

describe("formatDate", () => {
  it("formats an ISO string as DD/MM/YYYY", () => {
    expect(formatDate("2026-10-23T10:30:00.000Z")).toBe("23/10/2026")
  })

  it("formats a Date object", () => {
    expect(formatDate(new Date("2026-01-05T00:00:00.000Z"))).toBe("05/01/2026")
  })

  it("returns the em dash placeholder for null/undefined/empty/invalid values", () => {
    expect(formatDate(null)).toBe("—")
    expect(formatDate(undefined)).toBe("—")
    expect(formatDate("")).toBe("—")
    expect(formatDate("not-a-date")).toBe("—")
  })
})

describe("formatDateTime", () => {
  it("formats date plus 12h IST time", () => {
    // 16:05 UTC = 21:35 IST
    expect(formatDateTime("2026-10-23T16:05:00.000Z")).toBe("23/10/2026, 09:35 pm")
  })

  it("returns the em dash placeholder for null/undefined/empty/invalid values", () => {
    expect(formatDateTime(null)).toBe("—")
    expect(formatDateTime("garbage")).toBe("—")
  })
})
