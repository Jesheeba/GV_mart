import { isLostReasonPreset } from "./lead-lost-reasons"

/**
 * "Follow-up needed?" rules for the Log Outcome sheet. Pure so the Yes/No default and the Save gate can be unit-tested.
 * A closing (won/lost) outcome never schedules a follow-up, so the question is not asked for it.
 */
type OutcomeLike = { requires_followup: boolean; stage_effect: string | null }

export function isClosingOutcome(o: Pick<OutcomeLike, "stage_effect"> | null): boolean {
  return o?.stage_effect === "won" || o?.stage_effect === "lost"
}

/** The Yes/No is pre-filled from the outcome itself (a master rule, not a default); the user can change it. */
export function defaultFollowupNeeded(o: OutcomeLike): boolean {
  return !isClosingOutcome(o) && o.requires_followup
}

/** The question (and the date picker behind a Yes) only applies to a non-closing outcome. */
export function askFollowupQuestion(o: OutcomeLike | null): boolean {
  return !!o && !isClosingOutcome(o)
}

/** Whether the next follow-up is sent to the server: only for a non-closing outcome answered Yes. */
export function scheduleNext(o: OutcomeLike | null, needsFollowup: boolean | null): boolean {
  return askFollowupQuestion(o) && needsFollowup === true
}

/** Save gate for a normal (non-reopen) outcome: a Yes needs a valid date, a No needs nothing more. */
export function canSaveOutcome(args: {
  selected: OutcomeLike | null
  needsLostReason: boolean
  lostReasonValue: string
  needsFollowup: boolean | null
  nextValid: boolean
}): boolean {
  const { selected, needsLostReason, lostReasonValue, needsFollowup, nextValid } = args
  if (!selected) return false
  if (isClosingOutcome(selected)) return needsLostReason ? !!lostReasonValue : true
  return !needsFollowup || nextValid
}

/** What picking an outcome pre-fills (owner-approved master rules, 2026-11-26): follow-up needed, next type, lost-reason hint. */
export function outcomePrefill<T extends string>(o: OutcomeLike & { default_followup_type: T | null; lost_reason_hint: string | null }) {
  const hint = o.lost_reason_hint
  return {
    needsFollowup: defaultFollowupNeeded(o),
    followupType: o.default_followup_type,
    lostPreset: o.stage_effect === "lost" && hint && isLostReasonPreset(hint) ? hint : ("" as const),
  }
}

export type OutcomeChoice = "outcome" | "channel" | "lostReason" | "followupNeeded" | "nextType"

/**
 * The first required dropdown of a normal (non-reopen) outcome still on "Not set", in screen order, or null.
 * Save stays tappable while one is missing so it can show the inline error (choice-dropdowns-not-set, class C).
 */
export function missingOutcomeChoice(a: {
  selected: OutcomeLike | null
  channel: string | null
  lostPreset: string
  needsFollowup: boolean | null
  followupType: string | null
}): OutcomeChoice | null {
  if (!a.selected) return "outcome"
  if (!a.channel) return "channel"
  if (a.selected.stage_effect === "lost") return a.lostPreset ? null : "lostReason"
  if (!askFollowupQuestion(a.selected)) return null
  if (a.needsFollowup === null) return "followupNeeded"
  return a.needsFollowup && !a.followupType ? "nextType" : null
}
