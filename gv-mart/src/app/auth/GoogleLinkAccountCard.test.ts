import { describe, expect, it } from "vitest"
import { computeCooldownSeconds, selectVerifyErrorMessageKey } from "./GoogleLinkAccountCard"
import type { VerifyCustomerLinkCodeResult } from "@/services/auth"

describe("computeCooldownSeconds", () => {
  it("is the full 30s immediately after a request", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0)).toBe(30)
  })
  it("counts down as time passes", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0 + 10_000)).toBe(20)
    expect(computeCooldownSeconds(t0, t0 + 29_000)).toBe(1)
  })
  it("never goes negative once the cooldown has elapsed", () => {
    const t0 = 1_700_000_000_000
    expect(computeCooldownSeconds(t0, t0 + 30_000)).toBe(0)
    expect(computeCooldownSeconds(t0, t0 + 999_000)).toBe(0)
  })
})

describe("selectVerifyErrorMessageKey", () => {
  it("returns null before any verify attempt has resolved", () => {
    expect(selectVerifyErrorMessageKey(null, false)).toBeNull()
  })

  it("returns null on success (status: linked)", () => {
    const result: VerifyCustomerLinkCodeResult = { status: "linked" }
    expect(selectVerifyErrorMessageKey(result, false)).toBeNull()
  })

  it("shows the attempts-left message when attempts remain — same key regardless of the underlying reason", () => {
    const wrongCode: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 3 }
    const expiredLookingIdentical: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 3 }
    expect(selectVerifyErrorMessageKey(wrongCode, false)).toEqual({ key: "auth.linkAccountInvalidOrExpired", attemptsLeft: 3 })
    // Same response shape must produce the identical UI selection — there is no way for the
    // caller (or this function) to tell a wrong-code case apart from an expired-challenge case;
    // that collapsing happens server-side in verify_customer_link_code itself.
    expect(selectVerifyErrorMessageKey(expiredLookingIdentical, false)).toEqual(selectVerifyErrorMessageKey(wrongCode, false))
  })

  it("shows the locked/expired message (no attempts-left count) once attempts are exhausted", () => {
    const locked: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 0 }
    expect(selectVerifyErrorMessageKey(locked, false)).toEqual({ key: "auth.linkAccountLockedOrExpired" })
  })

  it("a thrown RPC error takes priority and shows a generic failure, regardless of any stale result", () => {
    const stale: VerifyCustomerLinkCodeResult = { status: "invalid_or_expired", attempts_left: 4 }
    expect(selectVerifyErrorMessageKey(stale, true)).toEqual({ key: "auth.linkAccountVerifyFailed" })
  })
})
