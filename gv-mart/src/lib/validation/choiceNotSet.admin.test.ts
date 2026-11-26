import { describe, expect, it } from "vitest"
import { tierOverridePatch } from "./techniciansAdmin"
import { memberSchema } from "./customer"
import { validateSpareSchedules } from "@/types/productLifecycle"
import { completeSegmentTree, emptySegmentDraft, emptySegmentLeaf, type SegmentDraftTree } from "@/services/audienceSegments"

/** choice-dropdowns-not-set (build-docs/features/choice-dropdowns-not-set.md) — admin HR/masters/automation/customer fields. */

describe("technician tier override (class A: Not set saves null)", () => {
  it("edit keeps saved value: an unchanged tier sends no tier_id", () => {
    expect(tierOverridePatch("tier-2", "tier-2")).toEqual({})
  })
  it("edit keeps saved value: a technician with no tier left on Not set sends nothing", () => {
    expect(tierOverridePatch("", null)).toEqual({})
    expect(tierOverridePatch("", undefined)).toEqual({})
  })
  it("A: changing a saved tier to Not set saves null (rank-1 fallback)", () => {
    expect(tierOverridePatch("", "tier-2")).toEqual({ tier_id: null })
  })
  it("a newly chosen tier is sent", () => {
    expect(tierOverridePatch("tier-3", "tier-2")).toEqual({ tier_id: "tier-3" })
    expect(tierOverridePatch("tier-1", null)).toEqual({ tier_id: "tier-1" })
  })
})

describe("segment rule builder (class C)", () => {
  const filled: SegmentDraftTree = { op: "and", conditions: [{ field: "customer.city", operator: "=", value: "Chennai" }] }

  it("AC1: a new segment has nothing pre-selected", () => {
    expect(emptySegmentDraft()).toEqual({ op: "", conditions: [{ field: "", operator: "", value: "" }] })
    expect(emptySegmentLeaf()).toEqual({ field: "", operator: "", value: "" })
  })

  it("AC2: segment rule incomplete until every part chosen", () => {
    expect(completeSegmentTree(emptySegmentDraft())).toBeNull()
    expect(completeSegmentTree({ ...filled, op: "" })).toBeNull()
    expect(completeSegmentTree({ ...filled, conditions: [{ field: "", operator: "=", value: "Chennai" }] })).toBeNull()
    expect(completeSegmentTree({ ...filled, conditions: [{ field: "customer.city", operator: "", value: "Chennai" }] })).toBeNull()
    expect(completeSegmentTree({ ...filled, conditions: [{ field: "customer.city", operator: "=", value: "  " }] })).toBeNull()
  })

  it("AC2: one unset condition among complete ones blocks the whole rule", () => {
    expect(completeSegmentTree({ ...filled, conditions: [...filled.conditions, emptySegmentLeaf()] })).toBeNull()
  })

  it("AC2: a yes/no field left on Not set is incomplete", () => {
    expect(completeSegmentTree({ op: "or", conditions: [{ field: "amc.active", operator: "", value: "" }] })).toBeNull()
  })

  it("rejects a field or operator outside the offered lists", () => {
    expect(completeSegmentTree({ op: "and", conditions: [{ field: "customer.ssn", operator: "=", value: "x" }] })).toBeNull()
    expect(completeSegmentTree({ op: "and", conditions: [{ field: "customer.city", operator: "like", value: "x" }] })).toBeNull()
  })

  it("a complete rule keeps the stored jsonb shape (boolean leaves use operator '=')", () => {
    const tree = completeSegmentTree({
      op: "or",
      conditions: [
        { field: "product.brand", operator: "contains", value: "Amaron" },
        { field: "warranty.active", operator: "", value: false },
      ],
    })
    expect(tree).toEqual({
      op: "or",
      conditions: [
        { field: "product.brand", operator: "contains", value: "Amaron" },
        { field: "warranty.active", operator: "=", value: false },
      ],
    })
  })
})

describe("spare schedule interval unit (class C)", () => {
  const row = { spareId: null, label: "Pre-filter", intervalValue: 6 }

  it("AC2: Not set blocks save with the unit-required message", () => {
    const r = validateSpareSchedules([{ ...row, intervalUnit: "" }])
    expect(r.valid).toBe(false)
    expect(r.rowErrors[0]).toEqual({ intervalUnit: "unitRequired" })
  })

  it("edit keeps saved value: a saved unit passes unchanged", () => {
    expect(validateSpareSchedules([{ ...row, intervalUnit: "years" }])).toEqual({ valid: true, rowErrors: [{}] })
  })
})

describe("member relation (class A)", () => {
  const member = { name: "Priya", mobile: "9876543210" }

  it("A: relation Not set saves as empty (undefined → null at the call site)", () => {
    const r = memberSchema.safeParse({ ...member, relation: "" })
    expect(r.success).toBe(true)
    expect(r.data?.relation).toBeUndefined()
  })

  it("edit keeps saved value", () => {
    expect(memberSchema.safeParse({ ...member, relation: "daughter" }).data?.relation).toBe("daughter")
  })

  it("rejects a relation outside the enum", () => {
    expect(memberSchema.safeParse({ ...member, relation: "cousin" }).success).toBe(false)
  })
})
