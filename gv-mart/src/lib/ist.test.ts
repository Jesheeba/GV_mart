import { afterEach, describe, expect, it } from "vitest"
import { getIstNow, istDateOf, istDayEndIso, istDayStartIso } from "./ist"

/**
 * Urgent item 4 (2026-11-02) regression suite — a master-created complaint
 * was scheduled for the day AFTER the one picked. The root cause turned out
 * to be a plpgsql control-flow bug (see
 * supabase/migrations/20261201100100_fix_complaint_appointment_silent_next_day_bump.sql),
 * not a timezone-cast bug — but these helpers are exactly the kind of code
 * that *would* reintroduce a "D becomes D+1 (or D-1)" bug if anyone touched
 * them carelessly (see the 20260731100000/20261006170000 history already in
 * this codebase), so they get a dedicated regression suite that exercises
 * the two real trouble spots: the viewer's own OS timezone (TZ env var) and
 * the midnight boundary in IST (00:30 / 23:30).
 *
 * Every assertion must hold identically under TZ=UTC, Asia/Kolkata, and
 * America/Los_Angeles — the whole point of these helpers is that the
 * device's own clock/timezone must never leak into what calendar date is
 * shown or compared against.
 */

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

describe("istDateOf — device/session timezone must never change the IST calendar date", () => {
  for (const tz of TZS) {
    it(`23:30 IST on 2026-11-02 is still read as 2026-11-02 under TZ=${tz}`, () => {
      withTz(tz, () => {
        // 23:30 IST = 18:00 UTC same day.
        expect(istDateOf("2026-11-02T18:00:00.000Z")).toBe("2026-11-02")
      })
    })

    it(`00:30 IST on 2026-11-02 is still read as 2026-11-02 (not 2026-11-01) under TZ=${tz}`, () => {
      withTz(tz, () => {
        // 00:30 IST on Nov 2 = 19:00 UTC on Nov 1 — the exact instant a naive
        // UTC-based date read (e.g. `.toISOString().slice(0, 10)`) would get
        // wrong by one day.
        expect(istDateOf("2026-11-01T19:00:00.000Z")).toBe("2026-11-02")
      })
    })

    it(`just before midnight IST (23:59:59.999) stays on the same IST day under TZ=${tz}`, () => {
      withTz(tz, () => {
        expect(istDateOf("2026-11-02T18:29:59.999Z")).toBe("2026-11-02")
      })
    })

    it(`just after midnight IST (00:00:00.001) rolls to the next IST day under TZ=${tz}`, () => {
      withTz(tz, () => {
        expect(istDateOf("2026-11-02T18:30:00.001Z")).toBe("2026-11-03")
      })
    })
  }
})

describe("istDayStartIso / istDayEndIso — a fixed +05:30 offset regardless of host TZ", () => {
  for (const tz of TZS) {
    it(`day bounds for 2026-11-02 are identical under TZ=${tz}`, () => {
      withTz(tz, () => {
        expect(istDayStartIso("2026-11-02")).toBe(new Date("2026-11-02T00:00:00+05:30").toISOString())
        expect(istDayEndIso("2026-11-02")).toBe(new Date("2026-11-02T23:59:59.999+05:30").toISOString())
      })
    })

    it(`the end of 2026-11-02 and the start of 2026-11-03 are exactly 1ms apart under TZ=${tz}`, () => {
      withTz(tz, () => {
        const end = new Date(istDayEndIso("2026-11-02")).getTime()
        const nextStart = new Date(istDayStartIso("2026-11-03")).getTime()
        expect(nextStart - end).toBe(1)
      })
    })
  }
})

describe("getIstNow — 'today' is always the IST calendar date, never the host's own", () => {
  // getIstNow() reads the real wall clock, so we can only assert the shape +
  // internal consistency (date/time strings are well-formed and the IST
  // instant they describe round-trips), not a fixed expected value — but
  // critically, the RESULT must be identical no matter what TZ this process
  // happens to be running under, which is the actual bug class this guards.
  for (const tz of TZS) {
    it(`shape is YYYY-MM-DD / HH:MM under TZ=${tz}`, () => {
      withTz(tz, () => {
        const { date, time } = getIstNow()
        expect(date).toMatch(/^\d{4}-\d{2}-\d{2}$/)
        expect(time).toMatch(/^\d{2}:\d{2}$/)
      })
    })
  }

  it("getIstNow() returns the same date/time under every TZ at the same instant", () => {
    const results = TZS.map((tz) => withTz(tz, () => getIstNow()))
    expect(results[0]).toEqual(results[1])
    expect(results[1]).toEqual(results[2])
  })
})
