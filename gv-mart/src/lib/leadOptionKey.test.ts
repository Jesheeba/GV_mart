import { describe, expect, it } from "vitest"
import { leadSourceKeyFromLabel } from "./lead-sources"

// quick_add_lead_option (SQL) must derive the same key as Masters does in the
// browser: lower(label) -> non [a-z0-9] runs to "_" -> trim "_". These are the
// cases the SQL test checks too, so client and DB agree on duplicates.
describe("quick-add F3b: lead option key rule matches Masters", () => {
  it.each([
    ["Instagram", "instagram"],
    ["  Walk-in  Customer ", "walk_in_customer"],
    ["Google Ads (Paid)", "google_ads_paid"],
    ["RO / UV", "ro_uv"],
  ])("%s → %s", (label, key) => {
    expect(leadSourceKeyFromLabel(label)).toBe(key)
  })
  it("label with no letters/digits gives an empty key (RPC rejects it)", () => {
    expect(leadSourceKeyFromLabel("!!!")).toBe("")
  })
})
