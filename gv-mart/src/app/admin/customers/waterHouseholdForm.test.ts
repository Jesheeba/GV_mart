import { describe, expect, it } from "vitest"
import { isWaterPatchEmpty, isWaterProfileDirty, waterFormDefaults, waterFormToPatch } from "./WaterHouseholdPanel"
import { waterValuesFromCustomer } from "@/components/shared/WaterHouseholdSummary"
import { followUpDateError, waterProfileSchema } from "@/lib/validation/customer"
import { isWaterFollowupTask, postponeDateError } from "@/lib/waterFollowup"

// build-docs/features/customer-water-household.md (WH-*) and water-solution-followup.md (FU-*).

describe("WH-1: edit form is pre-filled from the saved customer row", () => {
  const saved = waterValuesFromCustomer({
    water_source: "other",
    water_source_other: "Lake",
    water_tds_ppm: 410,
    water_ph: 7.1,
    water_hardness_ppm: 300,
    household_problems: ["Hair fall", "Skin rash"],
    water_recommended_solution: "Softener",
  })
  it("every field round-trips into the form, with the follow-up date from the task", () => {
    expect(waterFormDefaults(saved, "2026-12-05")).toEqual({
      waterSource: "other",
      waterSourceOther: "Lake",
      waterTdsPpm: 410,
      waterPh: 7.1,
      waterHardnessPpm: 300,
      householdProblems: [{ value: "Hair fall" }, { value: "Skin rash" }],
      recommendedSolution: "Softener",
      followUpDate: "2026-12-05",
    })
  })
  it("an empty profile still shows one blank problem row and blank fields", () => {
    const d = waterFormDefaults()
    expect(d.householdProblems).toEqual([{ value: "" }])
    expect(d.followUpDate).toBe("")
    expect(d.recommendedSolution).toBe("")
  })
  it("columns absent before the migration lands read as null, not a crash", () => {
    expect(waterValuesFromCustomer({})).toEqual({
      waterSource: null,
      waterSourceOther: null,
      waterTdsPpm: null,
      waterPh: null,
      waterHardnessPpm: null,
      householdProblems: null,
      waterRecommendedSolution: null,
    })
  })
})

describe("waterFormToPatch (what is written)", () => {
  it("blank numbers (NaN) save as null; source 'other' keeps its text, any other source drops it", () => {
    const p = waterFormToPatch({ waterSource: "corporation", waterSourceOther: "stale", waterTdsPpm: Number.NaN, waterPh: undefined, waterHardnessPpm: Number.NaN })
    expect(p).toMatchObject({ waterSource: "corporation", waterSourceOther: null, waterTdsPpm: null, waterPh: null, waterHardnessPpm: null })
    expect(waterFormToPatch({ waterSource: "other", waterSourceOther: "  Lake  " }).waterSourceOther).toBe("Lake")
  })
  it("problems are cleaned; blank solution saves null (DB refuses blank text)", () => {
    const p = waterFormToPatch({ householdProblems: [{ value: " Hair fall " }, { value: "" }, { value: "hair fall" }], recommendedSolution: "   " })
    expect(p.householdProblems).toEqual(["Hair fall"])
    expect(p.waterRecommendedSolution).toBeNull()
  })
  it("the follow-up date is never part of the customers patch (the task holds it)", () => {
    expect(waterFormToPatch({ followUpDate: "2026-12-05" })).not.toHaveProperty("followUpDate")
  })
  it("isWaterPatchEmpty: an untouched create step writes nothing; any single value counts", () => {
    expect(isWaterPatchEmpty(waterFormToPatch(waterFormDefaults()))).toBe(true)
    expect(isWaterPatchEmpty(waterFormToPatch({ waterHardnessPpm: 0 }))).toBe(false)
    expect(isWaterPatchEmpty(waterFormToPatch({ householdProblems: [{ value: "x" }] }))).toBe(false)
    expect(isWaterPatchEmpty(waterFormToPatch({ recommendedSolution: "RO" }))).toBe(false)
  })
  it("isWaterProfileDirty ignores the follow-up date", () => {
    expect(isWaterProfileDirty({ followUpDate: true })).toBe(false)
    expect(isWaterProfileDirty({ followUpDate: true, waterHardnessPpm: true })).toBe(true)
    expect(isWaterProfileDirty({})).toBe(false)
  })
})

describe("FU: date rules (mirror the RPCs)", () => {
  const today = "2026-11-26"
  it("follow-up date: blank, unchanged (even overdue), today and later are allowed; a new past date is not", () => {
    expect(followUpDateError("", null, today)).toBeNull()
    expect(followUpDateError(undefined, "2026-11-01", today)).toBeNull()
    expect(followUpDateError("2026-11-01", "2026-11-01", today)).toBeNull()
    expect(followUpDateError(today, null, today)).toBeNull()
    expect(followUpDateError("2026-12-01", null, today)).toBeNull()
    expect(followUpDateError("2026-11-25", null, today)).toBe("customers.errors.followUpDatePast")
    expect(followUpDateError("2026-11-25", "2026-12-01", today)).toBe("customers.errors.followUpDatePast")
  })
  it("postpone: strictly later than the current due date and not in the past", () => {
    expect(postponeDateError("2026-12-02", "2026-12-01", today)).toBeNull()
    expect(postponeDateError("2026-12-01", "2026-12-01", today)).toBe("tasks.waterFollowup.errors.notLater")
    expect(postponeDateError("2026-11-30", "2026-12-01", today)).toBe("tasks.waterFollowup.errors.notLater")
    expect(postponeDateError("2026-11-20", "2026-11-10", today)).toBe("tasks.waterFollowup.errors.past")
    expect(postponeDateError(today, "2026-11-10", today)).toBeNull()
    expect(postponeDateError("2026-12-02", null, today)).toBeNull()
  })
  it("schema: solution over 500 refused, malformed date refused, blank date allowed", () => {
    const long = waterProfileSchema.safeParse({ recommendedSolution: "x".repeat(501) })
    expect(long.success).toBe(false)
    if (!long.success) expect(long.error.issues[0].message).toBe("customers.errors.solutionTooLong")
    expect(waterProfileSchema.safeParse({ recommendedSolution: "x".repeat(500) }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ followUpDate: "05/12/2026" }).success).toBe(false)
    expect(waterProfileSchema.safeParse({ followUpDate: "" }).success).toBe(true)
    expect(waterProfileSchema.safeParse({ followUpDate: "2026-12-05" }).success).toBe(true)
  })
  it("only customer_water_followup tasks get the follow-up panel", () => {
    expect(isWaterFollowupTask("customer_water_followup")).toBe(true)
    expect(isWaterFollowupTask("arrival_location_mismatch")).toBe(false)
    expect(isWaterFollowupTask(null)).toBe(false)
  })
})
