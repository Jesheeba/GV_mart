/**
 * "Follow-up needed?" rules for the Log Outcome sheet. Pure so the Yes/No default and the Save gate can be unit-tested.
 * A closing (won/lost) outcome never schedules a follow-up, so the question is not asked for it.
 */
type OutcomeLike = { requires_followup: boolean; stage_effect: string | null }

export function isClosingOutcome(o: Pick<OutcomeLike, "stage_effect"> | null): boolean {
  return o?.stage_effect === "won" || o?.stage_effect === "lost"
}

/** The Yes/No starts on whatever the outcome itself asks for; the user can flip it. */
export function defaultFollowupNeeded(o: OutcomeLike): boolean {
  return !isClosingOutcome(o) && o.requires_followup
}

/** The question (and the date picker behind a Yes) only applies to a non-closing outcome. */
export function askFollowupQuestion(o: OutcomeLike | null): boolean {
  return !!o && !isClosingOutcome(o)
}

/** Whether the next follow-up is sent to the server: only for a non-closing outcome answered Yes. */
export function scheduleNext(o: OutcomeLike | null, needsFollowup: boolean): boolean {
  return askFollowupQuestion(o) && needsFollowup
}

/** Save gate for a normal (non-reopen) outcome: a Yes needs a valid date, a No needs nothing more. */
export function canSaveOutcome(args: {
  selected: OutcomeLike | null
  needsLostReason: boolean
  lostReasonValue: string
  needsFollowup: boolean
  nextValid: boolean
}): boolean {
  const { selected, needsLostReason, lostReasonValue, needsFollowup, nextValid } = args
  if (!selected) return false
  if (isClosingOutcome(selected)) return needsLostReason ? !!lostReasonValue : true
  return !needsFollowup || nextValid
}
