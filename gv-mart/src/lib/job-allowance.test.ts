import { describe, expect, it } from "vitest"
import { computeAllowedDurationMinutes, sumItemStandardMinutes } from "./job-allowance"

describe("sumItemStandardMinutes", () => {
  it("sums qty × standardTimeMinutes across items", () => {
    expect(
      sumItemStandardMinutes([
        { qty: 1, standardTimeMinutes: 10 }, // back wheel
        { qty: 1, standardTimeMinutes: 5 }, // horn
      ])
    ).toBe(15)
  })

  it("counts qty as a multiplier", () => {
    expect(sumItemStandardMinutes([{ qty: 3, standardTimeMinutes: 5 }])).toBe(15)
  })

  it("skips items with no standard time set, rather than treating null as 0 and shrinking the estimate", () => {
    expect(
      sumItemStandardMinutes([
        { qty: 1, standardTimeMinutes: 10 },
        { qty: 1, standardTimeMinutes: null },
        { qty: 1, standardTimeMinutes: undefined },
      ])
    ).toBe(10)
  })

  it("is 0 for an empty item list", () => {
    expect(sumItemStandardMinutes([])).toBe(0)
  })
})

const BASE_INPUT = {
  itemsStandardMinutesSum: 0,
  ticketEstimatedDurationMinutes: null as number | null,
  reviewAllowanceMinutes: 5,
  enquiryAllowanceMinutes: 5,
  reviewCollected: false,
  enquiryLoggedThisVisit: false,
}

describe("computeAllowedDurationMinutes", () => {
  it("returns null when neither an item-sum nor a ticket estimate exists (mirrors computeJobOverrun's never-invent-a-comparison contract)", () => {
    expect(computeAllowedDurationMinutes(BASE_INPUT)).toBeNull()
  })

  it("falls back to the ticket's type-based estimate when no items are known yet", () => {
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, ticketEstimatedDurationMinutes: 45 })).toBe(45)
  })

  it("uses the item-sum as the base once items are known, in place of the type default", () => {
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, itemsStandardMinutesSum: 15, ticketEstimatedDurationMinutes: 45 })).toBe(15)
  })

  it("GV.md's own worked example: back wheel 10 + horn 5 + review 5 = 20", () => {
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, itemsStandardMinutesSum: 15, reviewCollected: true })).toBe(20)
  })

  it("adds the enquiry allowance only when an enquiry was actually logged this visit", () => {
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, itemsStandardMinutesSum: 15, enquiryLoggedThisVisit: true })).toBe(20)
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, itemsStandardMinutesSum: 15, enquiryLoggedThisVisit: false })).toBe(15)
  })

  it("stacks both allowances when both conditions are met", () => {
    expect(
      computeAllowedDurationMinutes({ ...BASE_INPUT, itemsStandardMinutesSum: 15, reviewCollected: true, enquiryLoggedThisVisit: true })
    ).toBe(25)
  })

  it("treats a zero/negative base the same as no base at all", () => {
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, ticketEstimatedDurationMinutes: 0 })).toBeNull()
    expect(computeAllowedDurationMinutes({ ...BASE_INPUT, ticketEstimatedDurationMinutes: -5 })).toBeNull()
  })
})
