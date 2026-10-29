import { describe, expect, it } from "vitest"
import { classifyOnboardError } from "./auto-onboard"

// Mirrors the error strings customer_auto_onboard() actually raises
// (20261130100001_customer_auto_onboard_rpc.sql) -- the match-rule decisions
// themselves (0 matches -> create; 1 unlinked match -> link; 1
// already-linked-elsewhere match -> flag-and-create; >1 matches ->
// flag-and-create) are proven server-side in
// supabase/tests/customer_auto_onboard.test.sql; this covers the one
// decision the client makes from the RPC's outcome.
describe("classifyOnboardError", () => {
  it("classifies the staff_account refusal", () => {
    expect(classifyOnboardError(new Error("admin_link_customer_google_account: staff_account"))).toBe("staff_account")
    expect(classifyOnboardError(new Error("staff_account"))).toBe("staff_account")
  })

  it("classifies every other RPC error as generic", () => {
    expect(classifyOnboardError(new Error("customer_auto_onboard: no authenticated user"))).toBe("error")
    expect(classifyOnboardError(new Error("customer_auto_onboard: no Google sign-in found for this user"))).toBe("error")
    expect(classifyOnboardError(new Error("customer_auto_onboard: email not confirmed"))).toBe("error")
    expect(classifyOnboardError(new Error("network error"))).toBe("error")
  })

  it("handles a non-Error throw (e.g. a raw string or Supabase error shape)", () => {
    expect(classifyOnboardError("staff_account")).toBe("staff_account")
    expect(classifyOnboardError("some other failure")).toBe("error")
    expect(classifyOnboardError(undefined)).toBe("error")
    expect(classifyOnboardError(null)).toBe("error")
  })
})
