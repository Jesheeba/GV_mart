import { describe, expect, it } from "vitest"
import { buildLeadEditAuditDiff, findDuplicateMobileMatches, isLeadSourceEditAllowed, type DuplicateCandidate, type LeadEditableSnapshot } from "./lead-edit"

describe("findDuplicateMobileMatches", () => {
  it("returns every candidate when there is no self-lead to exclude", () => {
    const candidates: DuplicateCandidate[] = [{ id: "c1", name: "Priya", kind: "customer" }]
    expect(findDuplicateMobileMatches(candidates, undefined)).toEqual(candidates)
  })

  it("excludes the lead being edited from its own duplicate list", () => {
    const candidates: DuplicateCandidate[] = [
      { id: "lead-1", name: "Self", kind: "lead" },
      { id: "lead-2", name: "Other lead", kind: "lead" },
      { id: "cust-1", name: "Some customer", kind: "customer" },
    ]
    const result = findDuplicateMobileMatches(candidates, "lead-1")
    expect(result).toEqual([
      { id: "lead-2", name: "Other lead", kind: "lead" },
      { id: "cust-1", name: "Some customer", kind: "customer" },
    ])
  })

  it("returns empty when there are no candidates", () => {
    expect(findDuplicateMobileMatches([], "lead-1")).toEqual([])
  })
})

describe("isLeadSourceEditAllowed (referral-safety guard)", () => {
  it("allows no-op (unchanged) source, including unchanged referral", () => {
    expect(isLeadSourceEditAllowed("other", "other")).toBe(true)
    expect(isLeadSourceEditAllowed("referral", "referral")).toBe(true)
  })

  it("allows switching between two non-referral sources", () => {
    expect(isLeadSourceEditAllowed("walk_in", "whatsapp")).toBe(true)
    expect(isLeadSourceEditAllowed("other", "field")).toBe(true)
  })

  it("blocks flipping an existing referral lead away from referral", () => {
    expect(isLeadSourceEditAllowed("referral", "other")).toBe(false)
  })

  it("blocks manually setting source to referral on a non-referral lead", () => {
    expect(isLeadSourceEditAllowed("walk_in", "referral")).toBe(false)
  })
})

describe("buildLeadEditAuditDiff", () => {
  const base: LeadEditableSnapshot = {
    name: "Ravi",
    mobile: "9876543210",
    alternate_mobile: null,
    address_text: null,
    source: "walk_in",
    product_type_key: null,
    notes: null,
  }

  it("returns null when nothing changed (no audit row for a no-op save)", () => {
    expect(buildLeadEditAuditDiff(base, { ...base })).toBeNull()
  })

  it("returns the before/after pair when a tracked field changed", () => {
    const after: LeadEditableSnapshot = { ...base, name: "Ravi Kumar", alternate_mobile: "9123456780" }
    expect(buildLeadEditAuditDiff(base, after)).toEqual({ before: base, after })
  })

  it("detects a change even when only notes changed", () => {
    const after: LeadEditableSnapshot = { ...base, notes: "Called twice, no answer" }
    expect(buildLeadEditAuditDiff(base, after)).toEqual({ before: base, after })
  })
})
