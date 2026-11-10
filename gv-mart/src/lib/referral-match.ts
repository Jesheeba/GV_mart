// Connection-map follow-up, Finding F-05 (payroll-fixes2, 2026-10-29) —
// renew_amc_plan() now reports whether a free-typed referring-technician name
// matched: null (no name given), true (matched), or false (given but no
// match — must warn, not silently drop). Pure predicate so the warning
// condition is covered by a test independent of any network call.
export function shouldWarnReferralMismatch(referralMatched: boolean | null): boolean {
  return referralMatched === false
}
