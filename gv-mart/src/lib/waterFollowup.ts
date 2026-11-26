/** tasks.ref_type of a water solution follow-up (ref_id = customer). See 20261216110000_water_solution_followup.sql. */
export const WATER_FOLLOWUP_REF_TYPE = "customer_water_followup"

export function isWaterFollowupTask(refType: string | null | undefined): boolean {
  return refType === WATER_FOLLOWUP_REF_TYPE
}

/**
 * Postpone rule, mirroring postpone_water_followup: the new date must not be in the past (IST) and must be strictly
 * later than the current due date. Returns the i18n error key, or null when allowed. Dates are YYYY-MM-DD strings,
 * which compare correctly as text.
 */
export function postponeDateError(newDate: string, currentDue: string | null | undefined, todayIst: string): string | null {
  if (newDate < todayIst) return "tasks.waterFollowup.errors.past"
  if (currentDue && newDate <= currentDue) return "tasks.waterFollowup.errors.notLater"
  return null
}
