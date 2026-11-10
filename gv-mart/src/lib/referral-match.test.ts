import { describe, expect, it } from "vitest"
import { shouldWarnReferralMismatch } from "./referral-match"

describe("shouldWarnReferralMismatch", () => {
  it("does not warn when no referral name was given at all", () => {
    expect(shouldWarnReferralMismatch(null)).toBe(false)
  })
  it("does not warn when the name matched a real active technician", () => {
    expect(shouldWarnReferralMismatch(true)).toBe(false)
  })
  it("warns when a name was given but did not match", () => {
    expect(shouldWarnReferralMismatch(false)).toBe(true)
  })
})
