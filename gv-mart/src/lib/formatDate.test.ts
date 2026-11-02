import { afterEach, describe, expect, it } from "vitest"
import { formatDate, formatDateTime } from "./formatDate"

// the app tsconfig has no node types; this file only ever runs under vitest (node)
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env
const ORIGINAL_TZ = env.TZ
function withTz<T>(tz: string, fn: () => T): T {
  env.TZ = tz
  try {
    return fn()
  } finally {
    env.TZ = ORIGINAL_TZ
  }
}
const TZS = ["UTC", "Asia/Kolkata", "America/Los_Angeles"] as const
afterEach(() => {
  env.TZ = ORIGINAL_TZ
})

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

/**
 * Urgent item 4 (2026-11-02) regression — display side. A ticket appointment
 * stored correctly at 23:30 or 00:30 IST must still display on the right
 * calendar day no matter what timezone the viewing browser/process is set
 * to — formatDate/formatDateTime are always pinned to Asia/Kolkata
 * explicitly (not the host default), which is exactly what these tests pin
 * down for every TZ this org's devices realistically run under.
 */
describe("formatDate / formatDateTime — IST day never shifts with the viewer's own TZ", () => {
  for (const tz of TZS) {
    it(`23:30 IST on 2 Nov 2026 displays as 02/11/2026 under TZ=${tz}`, () => {
      withTz(tz, () => {
        // 23:30 IST = 18:00 UTC same day.
        expect(formatDate("2026-11-02T18:00:00.000Z")).toBe("02/11/2026")
        expect(formatDateTime("2026-11-02T18:00:00.000Z")).toBe("02/11/2026, 11:30 pm")
      })
    })

    it(`00:30 IST on 2 Nov 2026 displays as 02/11/2026, not 01/11/2026, under TZ=${tz}`, () => {
      withTz(tz, () => {
        // 00:30 IST on Nov 2 = 19:00 UTC on Nov 1 — the exact instant a bare
        // `.toLocaleDateString()` with no explicit timeZone (the historical
        // bug this file's header documents) would show one day early on a
        // UTC/US-timezone device.
        expect(formatDate("2026-11-01T19:00:00.000Z")).toBe("02/11/2026")
        expect(formatDateTime("2026-11-01T19:00:00.000Z")).toBe("02/11/2026, 12:30 am")
      })
    })
  }
})
