// Urgent item (2026-11-02): pure decision logic for the staff-side
// duplicate-contact warning banner (CustomerFormPage "Create Customer" people
// step + NewLeadForm's mobile field). Kept dependency-free from React/React
// Query on purpose -- this project's vitest config runs plain Node with no
// jsdom/@testing-library, so component/hook behaviour isn't unit-tested
// directly here; this module is what gets exercised in
// duplicateContactWarning.test.ts, and the React hook/component below are
// thin, deliberately-untested wrappers around it (same split as every other
// *.test.ts in src/lib).
//
// Never used to BLOCK a save -- find_duplicate_contacts
// (20261204130000_duplicate_contact_warning_rpc.sql, NOT applied yet) and the
// underlying create_customer_with_details / leads insert have no server-side
// enforcement, by design. This only decides when to show the warning and
// when the explicit "Create anyway" confirmation has been satisfied -- same
// "informational, surfaced only once there's a real conflict, never
// pre-emptive" shape as assign_ticket_technician's p_force override
// (see TicketDetailPage.tsx's force-reassign button).

export interface DuplicateContactMatch {
  source: "customer" | "lead"
  id: string
  name: string
  mobile: string | null
  email: string | null
  created_at: string
  ticket_count: number
  invoice_count: number
}

// Same shape as MOBILE_REGEX in lib/validation/customer.ts (10-digit Indian
// mobile, starts 6-9) -- a lookup is only worth firing once the typed value
// could plausibly BE a stored mobile number, not on every keystroke.
const MOBILE_LOOKUP_REGEX = /^[6-9]\d{9}$/
const EMAIL_LOOKUP_REGEX = /^[^@\s]+@[^@\s]+\.[^@\s]+$/

/** Whether a (debounced) mobile/email pair is complete enough to be worth
 * sending to find_duplicate_contacts at all. An empty string for a field
 * that wasn't given is expected and does not by itself disable the lookup --
 * only neither field being usable does. */
export function shouldLookUpDuplicates(mobile: string, email: string): boolean {
  return MOBILE_LOOKUP_REGEX.test(mobile.trim()) || EMAIL_LOOKUP_REGEX.test(email.trim())
}

export function hasDuplicateMatches(matches: DuplicateContactMatch[] | undefined | null): boolean {
  return Array.isArray(matches) && matches.length > 0
}

/** Create/Save must never be hard-blocked by this warning. Once a real match
 * is shown, though, Save requires the explicit "Create anyway" confirmation
 * rather than sailing through silently. */
export function canSubmitWithWarning(matches: DuplicateContactMatch[] | undefined | null, confirmed: boolean): boolean {
  return !hasDuplicateMatches(matches) || confirmed
}

/** Identifies which (mobile, email) pair a given "Create anyway" confirmation
 * belongs to, so a confirm given for one number doesn't silently carry over
 * once the user edits the field to a different number afterwards. Callers
 * reset their `confirmed` state whenever this key changes. */
export function duplicateWarningKey(mobile: string, email: string): string {
  return `${mobile.trim()}|${email.trim().toLowerCase()}`
}
