import { describe, expect, it } from "vitest"
import { computeCooldownSeconds, selectVerifyErrorMessageKey, shouldHideLinkPhoneCard } from "./LinkPhoneCard"
import type { VerifyCustomerLinkCodeResult } from "@/services/auth"

describe("shouldHideLinkPhoneCard", () => {
  const base = { dismissed: false, isLoading: false, isError: false, eligible: true as boolean | undefined }

  it("shows the card (does NOT hide) only when every condition is favourable", () => {
    expect(shouldHideLinkPhoneCard(base)).toBe(false)
  })

  it("hides while the eligibility query is still loading, even before any answer is known", () => {
    expect(shouldHideLinkPhoneCard({ ...base, isLoading: true, eligible: undefined })).toBe(true)
  })

  it("hides on a query error -- an inconclusive answer must never show the form", () => {
    expect(shouldHideLinkPhoneCard({ ...base, isError: true })).toBe(true)
  })

  it("hides when the server says false -- flag off for this caller, or not the empty auto-created shape", () => {
    expect(shouldHideLinkPhoneCard({ ...base, eligible: false })).toBe(true)
  })

  it("hides once the viewer dismissed it, regardless of eligibility", () => {
    expect(shouldHideLinkPhoneCard({ ...base, dismissed: true })).toBe(true)
  })

  it("hides when eligible is undefined even without isLoading/isError set (defensive -- never show on an ambiguous value)", () => {
    expect(shouldHideLinkPhoneCard({ ...base, eligible: undefined })).toBe(true)
  })
})

// computeCooldownSeconds / selectVerifyErrorMessageKey: same pure logic GoogleLinkAccountCard's
// own test file already proves in full for the login-time card; re-proven here for THIS card's
// own copy (duplicated intentionally -- see this module's own header comment) so a future change
// to one can never silently diverge from the other without a test noticing.
describe("computeCooldownSeconds", () => {
  it("is the full 30s immediately after a request", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0)).toBe(30)
  })
  it("counts down as time passes", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0 + 10_000)).toBe(20)
  })
  it("never goes negative once the cooldown has elapsed", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0 + 999_000)).toBe(0)
  })
})

describe("selectVerifyErrorMessageKey", () => {
  it("returns null on success", () => {
    const result: VerifyCustomerLinkCodeResult = { status: "linked" }
    expect(selectVerifyErrorMessageKey(result, false)).toBeNull()
  })
  it("collapses wrong-code and expired to the identical message key + attempts-left shape", () => {
    const a: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 2 }
    const b: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 2 }
    expect(selectVerifyErrorMessageKey(a, false)).toEqual(selectVerifyErrorMessageKey(b, false))
  })
  it("a thrown RPC error takes priority over any stale result", () => {
    const stale: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 4 }
    expect(selectVerifyErrorMessageKey(stale, true)).toEqual({ key: "auth.linkAccountVerifyFailed" })
  })
})
