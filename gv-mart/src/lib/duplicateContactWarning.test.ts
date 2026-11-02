import { describe, expect, it } from "vitest"
import {
  canSubmitWithWarning,
  duplicateWarningKey,
  hasDuplicateMatches,
  shouldLookUpDuplicates,
  type DuplicateContactMatch,
} from "./duplicateContactWarning"

function match(overrides: Partial<DuplicateContactMatch> = {}): DuplicateContactMatch {
  return {
    source: "customer",
    id: "c1",
    name: "Ashok Kumar",
    mobile: "9843603231",
    email: null,
    created_at: "2026-10-28T07:29:42.410392+00:00",
    ticket_count: 0,
    invoice_count: 0,
    ...overrides,
  }
}

describe("shouldLookUpDuplicates", () => {
  it("fires for a complete 10-digit Indian mobile", () => {
    expect(shouldLookUpDuplicates("9843603231", "")).toBe(true)
  })

  it("does not fire for a partial mobile (debounce target, not yet a real number)", () => {
    expect(shouldLookUpDuplicates("984360", "")).toBe(false)
  })

  it("does not fire for a mobile starting 0-5 (not a valid Indian mobile prefix)", () => {
    expect(shouldLookUpDuplicates("5843603231", "")).toBe(false)
  })

  it("fires for a syntactically valid email even with no mobile", () => {
    expect(shouldLookUpDuplicates("", "owner@example.com")).toBe(true)
  })

  it("does not fire for an incomplete email", () => {
    expect(shouldLookUpDuplicates("", "owner@example")).toBe(false)
  })

  it("trims surrounding whitespace before checking either field", () => {
    expect(shouldLookUpDuplicates("  9843603231  ", "")).toBe(true)
    expect(shouldLookUpDuplicates("", "  owner@example.com  ")).toBe(true)
  })

  it("does not fire when both fields are empty", () => {
    expect(shouldLookUpDuplicates("", "")).toBe(false)
  })
})

describe("hasDuplicateMatches", () => {
  it("is false for undefined/null/empty", () => {
    expect(hasDuplicateMatches(undefined)).toBe(false)
    expect(hasDuplicateMatches(null)).toBe(false)
    expect(hasDuplicateMatches([])).toBe(false)
  })

  it("is true once at least one match comes back", () => {
    expect(hasDuplicateMatches([match()])).toBe(true)
  })
})

describe("canSubmitWithWarning", () => {
  it("allows submit when there are no matches, confirmed or not", () => {
    expect(canSubmitWithWarning(undefined, false)).toBe(true)
    expect(canSubmitWithWarning([], false)).toBe(true)
  })

  it("blocks submit when matches exist and the user has not confirmed -- never a hard block overall, just this gate", () => {
    expect(canSubmitWithWarning([match()], false)).toBe(false)
  })

  it("allows submit once matches exist AND the user explicitly confirmed (the 'Create anyway' step)", () => {
    expect(canSubmitWithWarning([match()], true)).toBe(true)
  })
})

describe("duplicateWarningKey", () => {
  it("is stable for the same mobile+email regardless of case/whitespace in the email", () => {
    expect(duplicateWarningKey("9843603231", "  Owner@Example.com ")).toBe(duplicateWarningKey("9843603231", "owner@example.com"))
  })

  it("changes when the mobile changes -- so a stale 'Create anyway' confirm doesn't carry over to a new number", () => {
    expect(duplicateWarningKey("9843603231", "")).not.toBe(duplicateWarningKey("9843603232", ""))
  })

  it("changes when the email changes but the mobile stays the same", () => {
    expect(duplicateWarningKey("9843603231", "a@example.com")).not.toBe(duplicateWarningKey("9843603231", "b@example.com"))
  })
})
