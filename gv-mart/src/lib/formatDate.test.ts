import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { formatDate, formatDateTime, formatShortDate, formatShortDateTime, formatShortDateTimeRange, formatTime } from "./formatDate"

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

describe("formatShortDate / formatShortDateTime (date-display)", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    // "now" = 26 Nov 2026, 15:30 IST
    vi.setSystemTime(new Date("2026-11-26T10:00:00.000Z"))
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("AC4: same IST year omits the year — '6 Oct, 10:00 am'", () => {
    expect(formatShortDateTime("2026-10-06T04:30:00.000Z")).toBe("6 Oct, 10:00 am")
    expect(formatShortDate("2026-10-06T04:30:00.000Z")).toBe("6 Oct")
  })

  it("AC4: a different IST year includes the year — '6 Oct 2025, 10:00 am'", () => {
    expect(formatShortDateTime("2025-10-06T04:30:00.000Z")).toBe("6 Oct 2025, 10:00 am")
    expect(formatShortDate("2027-01-02T04:30:00.000Z")).toBe("2 Jan 2027")
  })

  it("AC4: the year rule uses the IST year of 'now', not UTC (31 Dec 19:00 UTC is already 1 Jan IST)", () => {
    vi.setSystemTime(new Date("2026-12-31T19:00:00.000Z")) // 1 Jan 2027, 00:30 IST
    expect(formatShortDate("2027-01-01T04:30:00.000Z")).toBe("1 Jan")
    expect(formatShortDate("2026-12-31T04:30:00.000Z")).toBe("31 Dec 2026")
  })

  for (const tz of TZS) {
    it(`AC4: a UTC instant that is the next day in IST shows the IST day under TZ=${tz}`, () => {
      withTz(tz, () => {
        expect(formatShortDateTime("2026-10-05T19:00:00.000Z")).toBe("6 Oct, 12:30 am")
      })
    })
  }

  it("AC4: null/undefined/empty/invalid → '—'", () => {
    for (const v of [null, undefined, "", "not-a-date"]) {
      expect(formatShortDate(v)).toBe("—")
      expect(formatShortDateTime(v)).toBe("—")
    }
  })

  it("AC4: time part is the same 12-hour lowercase am/pm as formatTime", () => {
    const iso = "2026-10-06T10:35:00.000Z" // 4:05 pm IST
    expect(formatShortDateTime(iso)).toBe(`6 Oct, ${formatTime(iso)}`)
    expect(formatTime(iso)).toBe("4:05 pm")
  })
})

describe("invoice/quotation print date (date-display: InvoicePage ddmmyyyy → formatDate)", () => {
  for (const tz of TZS) {
    it(`AC3: an invoice raised at 00:30 IST prints the IST day (DD/MM/YYYY) under TZ=${tz}`, () => {
      withTz(tz, () => {
        // 00:30 IST on 6 Oct = 19:00 UTC on 5 Oct — the old device-TZ ddmmyyyy showed 05-10-2026 on a UTC device.
        expect(formatDate("2026-10-05T19:00:00.000Z")).toBe("06/10/2026")
        // 23:59 IST on 5 Oct stays 5 Oct.
        expect(formatDate("2026-10-05T18:29:00.000Z")).toBe("05/10/2026")
      })
    })
  }
})

describe("formatShortDateTimeRange (date-display: Start/Close time on one line)", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-11-26T10:00:00.000Z"))
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("AC2: same IST day shows the date once — '6 Oct, 10:00 am – 11:30 am'", () => {
    expect(formatShortDateTimeRange("2026-10-06T04:30:00.000Z", "2026-10-06T06:00:00.000Z")).toBe("6 Oct, 10:00 am – 11:30 am")
  })

  it("AC2: a range crossing IST midnight shows both dates", () => {
    // 10:00 pm IST 6 Oct → 1:00 am IST 7 Oct
    expect(formatShortDateTimeRange("2026-10-06T16:30:00.000Z", "2026-10-06T19:30:00.000Z")).toBe("6 Oct, 10:00 pm – 7 Oct, 1:00 am")
  })

  it("AC2: missing end shows '…'; missing/invalid start shows '—'", () => {
    expect(formatShortDateTimeRange("2026-10-06T04:30:00.000Z", null)).toBe("6 Oct, 10:00 am – …")
    expect(formatShortDateTimeRange(null, "2026-10-06T06:00:00.000Z")).toBe("—")
    expect(formatShortDateTimeRange("garbage", null)).toBe("—")
  })
})
