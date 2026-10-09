import { describe, expect, it } from "vitest"
import en from "./en.json"
import ta from "./ta.json"

function keys(o: unknown, prefix = ""): string[] {
  if (o === null || typeof o !== "object") return [prefix]
  return Object.entries(o as Record<string, unknown>).flatMap(([k, v]) => keys(v, prefix ? `${prefix}.${k}` : k))
}

// Guards label edits: renaming a JSON key instead of its value silently shows
// the raw key in the UI for that language.
// Pre-existing gaps (not part of batch 17); remove once Tamil exists for them.
const KNOWN_MISSING_IN_TA = new Set([
  "technician.sync.jobKind.attendance.checkout",
  "technician.sync.jobKind.rating.mark_review_clicked",
  "technician.sync.jobKind.amc.sell_onsite",
])

describe("en/ta translation key parity", () => {
  const enKeys = new Set(keys(en))
  const taKeys = new Set(keys(ta))
  it("every English key exists in Tamil", () => {
    expect([...enKeys].filter((k) => !taKeys.has(k) && !KNOWN_MISSING_IN_TA.has(k))).toEqual([])
  })
  it("every Tamil key exists in English", () => {
    expect([...taKeys].filter((k) => !enKeys.has(k))).toEqual([])
  })
})
