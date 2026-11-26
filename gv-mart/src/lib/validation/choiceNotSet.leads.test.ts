import { describe, expect, it } from "vitest"
import { leadSchema } from "./automation"
import { canSaveOutcome, missingOutcomeChoice, outcomePrefill, scheduleNext } from "@/lib/lead-outcome-followup"
import { canSetFollowup } from "@/lib/lead-followups"

/** choice-dropdowns-not-set (build-docs/features/choice-dropdowns-not-set.md), Leads area. */

const messages = (r: { error?: { issues: { path: PropertyKey[]; message: string }[] } }) => (r.error?.issues ?? []).map((i) => `${i.path.join(".")}:${i.message}`)

describe("leadSchema (New lead form)", () => {
  const base = { name: "Ravi Kumar", source: "walk_in" }

  it("AC1: no default fills in a source — a new lead left on Not set has none", () => {
    const r = leadSchema.safeParse({ name: "Ravi Kumar" })
    expect(r.success).toBe(false)
    expect(r.data).toBeUndefined()
  })

  it("AC2 (class C): Not set source blocks save with the source-required message", () => {
    expect(messages(leadSchema.safeParse({ ...base, source: "" }))).toEqual(["source:leads.errors.sourceRequired"])
  })

  it("AC2: a chosen source saves", () => {
    expect(leadSchema.safeParse(base).success).toBe(true)
  })

  it("A: product category and kind left on Not set pass (the form saves them as null)", () => {
    const r = leadSchema.safeParse({ ...base, productCategory: "", kind: "" })
    expect(r.success).toBe(true)
    expect(r.data?.productCategory || null).toBeNull()
    expect(r.data?.kind || null).toBeNull()
  })

  it("AC3: chosen product category and kind are kept", () => {
    expect(leadSchema.safeParse({ ...base, productCategory: "ro", kind: "spare" }).data).toMatchObject({ productCategory: "ro", kind: "spare" })
  })
})

describe("Set / bulk follow-up type (class C)", () => {
  const next = { date: "2099-01-05", time: "10:00", exact: false }
  it("AC2: Not set follow-up type cannot be saved", () => {
    expect(canSetFollowup({ type: "", next })).toBe(false)
  })
  it("AC2: a chosen type with a valid time can", () => {
    expect(canSetFollowup({ type: "visit", next })).toBe(true)
  })
})

describe("Log outcome sheet dropdowns", () => {
  const callback = { requires_followup: true, stage_effect: "contacted", default_followup_type: "call" as const, lost_reason_hint: null }
  const optional = { requires_followup: false, stage_effect: null, default_followup_type: null, lost_reason_hint: null }
  const lost = { requires_followup: false, stage_effect: "lost", default_followup_type: null, lost_reason_hint: "price_too_high" }
  const won = { requires_followup: false, stage_effect: "won", default_followup_type: null, lost_reason_hint: null }
  const chosen = { channel: "call", lostPreset: "", needsFollowup: true as boolean | null, followupType: "call" as string | null }

  it("follow-up needed starts unset: before an outcome it is neither Yes nor No and nothing is scheduled", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: null, needsFollowup: null })).toBe("outcome")
    expect(scheduleNext(callback, null)).toBe(false)
  })

  it("outcome pre-fill still applies: follow-up needed, next type and lost-reason hint come from the outcome", () => {
    expect(outcomePrefill(callback)).toEqual({ needsFollowup: true, followupType: "call", lostPreset: "" })
    expect(outcomePrefill(optional)).toEqual({ needsFollowup: false, followupType: null, lostPreset: "" })
    expect(outcomePrefill(lost)).toEqual({ needsFollowup: false, followupType: null, lostPreset: "price_too_high" })
  })

  it("outcome pre-fill ignores a hint that is not a preset, and a hint on a non-lost outcome", () => {
    expect(outcomePrefill({ ...lost, lost_reason_hint: "free text" }).lostPreset).toBe("")
    expect(outcomePrefill({ ...callback, lost_reason_hint: "price_too_high" }).lostPreset).toBe("")
  })

  it("AC2 (class C): Not set outcome blocks save", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: null })).toBe("outcome")
  })

  it("AC2 (class C): Not set channel blocks save", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: callback, channel: null })).toBe("channel")
  })

  it("AC2 (class C): follow-up needed set back to Not set blocks save", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: optional, needsFollowup: null })).toBe("followupNeeded")
  })

  it("AC2 (class C): Yes with next type on Not set blocks save; No needs no type", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: callback, followupType: null })).toBe("nextType")
    expect(missingOutcomeChoice({ ...chosen, selected: callback, needsFollowup: false, followupType: null })).toBeNull()
  })

  it("AC2 (class C): lost with reason on Not set blocks save; a chosen reason passes", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: lost, lostPreset: "" })).toBe("lostReason")
    expect(missingOutcomeChoice({ ...chosen, selected: lost, lostPreset: "other" })).toBeNull()
  })

  it("won needs no follow-up answer or type (the question is not asked)", () => {
    expect(missingOutcomeChoice({ ...chosen, selected: won, needsFollowup: null, followupType: null })).toBeNull()
  })

  it("reports the first missing dropdown in screen order", () => {
    expect(missingOutcomeChoice({ selected: lost, channel: null, lostPreset: "", needsFollowup: null, followupType: null })).toBe("channel")
  })

  it("Save stays tappable for an unanswered follow-up question so the inline error can show", () => {
    expect(canSaveOutcome({ selected: optional, needsLostReason: false, lostReasonValue: "", needsFollowup: null, nextValid: false })).toBe(true)
  })
})
