// Incentive audit, Finding H-03 (payroll-fixes, 2026-10-29) — pure helpers for the
// "logged to Accounts -> locked -> reopen" lifecycle, extracted so the UI's
// lock/recompute/reopen gating logic is unit-testable without a DB round trip.
// The actual enforcement lives server-side (compute_salary refuses a locked row,
// log_salary_to_accounts is the only writer of `locked_at`) — these helpers exist
// so the UI's disabled/visible states agree with that server behaviour instead of
// re-deriving it ad hoc at each call site.

export type SalaryLockState = { locked_at: string | null }

/** True once this salary row has been posted to Accounts (Finding H-03). */
export function isSalaryLocked(row: SalaryLockState): boolean {
  return row.locked_at != null
}

/** compute_salary() refuses a locked row server-side; this mirrors that so the
 * Recompute button can be disabled instead of letting the master wait for an
 * error that is already certain. */
export function canRecompute(row: SalaryLockState): boolean {
  return !isSalaryLocked(row)
}

/** "Log to Accounts" is a one-shot action per salaries row (one non-voided
 * expense per salary_id, enforced by a DB unique index) — once locked, the only
 * way to post again is reopen_salary_posting() first. */
export function canLogToAccounts(row: SalaryLockState): boolean {
  return !isSalaryLocked(row)
}

/** The Reopen action only makes sense (and the RPC only succeeds) on a locked row. */
export function canReopen(row: SalaryLockState): boolean {
  return isSalaryLocked(row)
}

/** Formats the DB's own "already logged" response into the one line the UI
 * shows — kept as a pure function so the exact wording is covered by a test
 * independent of any network call. Mirrors what log_salary_to_accounts() itself
 * returns in `message`, for the (rare) case the caller wants to re-derive it
 * client-side from just a date. */
export function alreadyLoggedMessage(date: string | null): string {
  return `already logged on ${date ?? "an earlier date"}`
}

// Connection-map follow-up, Finding F-01 (payroll-fixes2, 2026-10-29) — pure
// predicate for the HR Salary screen's shortfall warning, so the "do not just
// hide it" requirement is covered by a test independent of any network call.
export type SalaryShortfallState = { shortfall_amount: number }

/** compute_salary() floors `net` at zero and records whatever the floor
 * absorbed in `shortfall_amount` (0 when nothing was floored). This is the
 * single source of truth for whether the UI shows the warning line. */
export function hasShortfall(row: SalaryShortfallState): boolean {
  return row.shortfall_amount > 0
}
