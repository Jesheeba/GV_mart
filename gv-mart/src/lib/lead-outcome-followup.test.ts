import { describe, expect, it } from "vitest"
import { askFollowupQuestion, canSaveOutcome, defaultFollowupNeeded, isClosingOutcome, scheduleNext } from "./lead-outcome-followup"

const required = { requires_followup: true, stage_effect: "contacted" }
const requiredNoStage = { requires_followup: true, stage_effect: null } // e.g. "Not reachable"
const optional = { requires_followup: false, stage_effect: null }
const won = { requires_followup: false, stage_effect: "won" }
const lost = { requires_followup: false, stage_effect: "lost" }

describe("Follow-up needed? default and gating", () => {
  it("defaults Yes only for non-closing outcomes that require a follow-up", () => {
    expect(defaultFollowupNeeded(required)).toBe(true)
    expect(defaultFollowupNeeded(requiredNoStage)).toBe(true)
    expect(defaultFollowupNeeded(optional)).toBe(false)
    expect(defaultFollowupNeeded(won)).toBe(false)
    expect(defaultFollowupNeeded(lost)).toBe(false)
  })
  it("a closing outcome with requires_followup mistakenly true still defaults to No", () => {
    expect(defaultFollowupNeeded({ requires_followup: true, stage_effect: "lost" })).toBe(false)
  })
  it("asks the question for every non-closing outcome, never for won/lost", () => {
    expect(askFollowupQuestion(required)).toBe(true)
    expect(askFollowupQuestion(optional)).toBe(true)
    expect(askFollowupQuestion(won)).toBe(false)
    expect(askFollowupQuestion(lost)).toBe(false)
    expect(askFollowupQuestion(null)).toBe(false)
  })
  it("sends the next follow-up only for a non-closing outcome answered Yes", () => {
    expect(scheduleNext(required, true)).toBe(true)
    expect(scheduleNext(required, false)).toBe(false)
    expect(scheduleNext(optional, true)).toBe(true)
    expect(scheduleNext(won, true)).toBe(false)
    expect(scheduleNext(null, true)).toBe(false)
  })
  it("closing outcomes are identified by stage effect", () => {
    expect(isClosingOutcome(won)).toBe(true)
    expect(isClosingOutcome(lost)).toBe(true)
    expect(isClosingOutcome(required)).toBe(false)
    expect(isClosingOutcome(requiredNoStage)).toBe(false)
    expect(isClosingOutcome(null)).toBe(false)
  })
})

describe("Save gate", () => {
  const base = { needsLostReason: false, lostReasonValue: "", needsFollowup: true, nextValid: false }
  it("nothing selected -> cannot save", () => {
    expect(canSaveOutcome({ ...base, selected: null })).toBe(false)
  })
  it("Yes needs a valid date; No needs none", () => {
    expect(canSaveOutcome({ ...base, selected: required, needsFollowup: true, nextValid: false })).toBe(false)
    expect(canSaveOutcome({ ...base, selected: required, needsFollowup: true, nextValid: true })).toBe(true)
    expect(canSaveOutcome({ ...base, selected: required, needsFollowup: false, nextValid: false })).toBe(true)
  })
  it("an optional outcome answered Yes also needs a date", () => {
    expect(canSaveOutcome({ ...base, selected: optional, needsFollowup: true, nextValid: false })).toBe(false)
    expect(canSaveOutcome({ ...base, selected: optional, needsFollowup: false, nextValid: false })).toBe(true)
  })
  it("won needs nothing; lost needs a reason", () => {
    expect(canSaveOutcome({ ...base, selected: won, needsFollowup: false })).toBe(true)
    expect(canSaveOutcome({ ...base, selected: lost, needsLostReason: true, lostReasonValue: "", needsFollowup: false })).toBe(false)
    expect(canSaveOutcome({ ...base, selected: lost, needsLostReason: true, lostReasonValue: "Too costly", needsFollowup: false })).toBe(true)
  })
})
