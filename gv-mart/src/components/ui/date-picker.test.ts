import { afterEach, describe, expect, it } from "vitest"
import { formatDateOnly, parseDateOnly } from "./date-picker"

/**
 * Urgent item 4 (2026-11-02) regression — write side. This is the exact
 * "picked date -> p_scheduled_date string" contract NewComplaintPage.tsx
 * (admin) and BookServicePage.tsx (customer) both go through before calling
 * createComplaintTicket/bookServiceTicket. It must be a no-op round trip —
 * the "YYYY-MM-DD" string the admin picks on screen must be the exact
 * string sent to the RPC — under every host timezone, since `new Date(y, m,
 * d)` + getFullYear/getMonth/getDate (what this file actually uses) stays
 * in local calendar fields the whole way and never goes through UTC. This
 * guards against the classic regression (see src/lib/ist.ts's own header
 * comment and the 20260731100000 migration) of someone "simplifying" this
 * into `date.toISOString().slice(0, 10)`, which silently shifts the date by
 * one day for exactly the host timezones under test here.
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

describe("parseDateOnly / formatDateOnly round trip", () => {
  const pickedDates = ["2026-11-02", "2026-02-11", "2026-01-01", "2026-12-31"]

  for (const tz of TZS) {
    for (const picked of pickedDates) {
      it(`"${picked}" picked on screen round-trips to the identical string under TZ=${tz}`, () => {
        withTz(tz, () => {
          const parsed = parseDateOnly(picked)
          expect(parsed).not.toBeNull()
          expect(formatDateOnly(parsed!)).toBe(picked)
        })
      })
    }

    it(`parses "2026-11-02" to local calendar fields 2026/10(0-based)/02, not shifted a day, under TZ=${tz}`, () => {
      withTz(tz, () => {
        const parsed = parseDateOnly("2026-11-02")!
        expect(parsed.getFullYear()).toBe(2026)
        expect(parsed.getMonth()).toBe(10) // November, 0-based
        expect(parsed.getDate()).toBe(2)
      })
    })
  }

  it("returns null for empty/undefined/null input", () => {
    expect(parseDateOnly("")).toBeNull()
    expect(parseDateOnly(undefined)).toBeNull()
    expect(parseDateOnly(null)).toBeNull()
  })
})
