import { describe, expect, it } from "vitest"
import { BULK_MAX_PER_DAY, isValidPerDay, spreadPlan, summariseSkipped } from "./lead-spread"

describe("spreadPlan", () => {
  it("rounds up to whole working days and reports the last day's load", () => {
    expect(spreadPlan(64, 25)).toEqual({ days: 3, lastDayCount: 14 })
    expect(spreadPlan(7, 2)).toEqual({ days: 4, lastDayCount: 1 })
    expect(spreadPlan(50, 25)).toEqual({ days: 2, lastDayCount: 25 })
    expect(spreadPlan(1, 25)).toEqual({ days: 1, lastDayCount: 1 })
  })
  it("returns null for nonsense input", () => {
    expect(spreadPlan(0, 5)).toBeNull()
    expect(spreadPlan(5, 0)).toBeNull()
    expect(spreadPlan(2.5, 5)).toBeNull()
    expect(spreadPlan(5, Number.NaN)).toBeNull()
  })
})

describe("isValidPerDay", () => {
  it("accepts 1..100 whole numbers only", () => {
    expect(isValidPerDay("1")).toBe(true)
    expect(isValidPerDay(" 25 ")).toBe(true)
    expect(isValidPerDay(String(BULK_MAX_PER_DAY))).toBe(true)
    for (const bad of ["", "0", "101", "-3", "2.5", "abc", "1e2"]) expect(isValidPerDay(bad), bad).toBe(false)
  })
})

describe("summariseSkipped", () => {
  it("counts skipped leads per reason", () => {
    expect(summariseSkipped([{ reason: "closed" }, { reason: "has_followup" }, { reason: "closed" }, { reason: "not_yours" }])).toEqual({ closed: 2, has_followup: 1, not_yours: 1 })
    expect(summariseSkipped([])).toEqual({})
  })
})
