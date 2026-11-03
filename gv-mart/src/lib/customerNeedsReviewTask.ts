/**
 * Item 5(c): pure helpers for the "Customer needs account review" task
 * (ref_type = 'customer_needs_review', created server-side when a sign-in
 * matched multiple existing records or an already-linked one and the system
 * deliberately didn't guess -- see customer_auto_onboard() / the phone-OTP
 * merge-on-verify RPC). Kept separate from TaskDetailDialog.tsx so the
 * discriminator logic is unit-testable without rendering the dialog.
 */

export const CUSTOMER_NEEDS_REVIEW_REF_TYPE = "customer_needs_review"

export function isCustomerNeedsReviewTask(refType: string | null | undefined): boolean {
  return refType === CUSTOMER_NEEDS_REVIEW_REF_TYPE
}

/**
 * The match lookup (find_duplicate_contacts) needs a mobile/email to search
 * on -- the flagged customer's own record. A customer created by this path
 * may have only a mobile, only an email, or (rarely) neither yet -- in the
 * last case there is nothing to look up and the caller should show a plain
 * "no contact info yet" state instead of calling the RPC with two empty
 * strings (which find_duplicate_contacts itself also treats as "nothing to
 * match on" and returns zero rows for, but skipping the call avoids a
 * pointless round trip).
 */
export function hasLookupableContact(mobile: string | null | undefined, email: string | null | undefined): boolean {
  return !!(mobile && mobile.trim()) || !!(email && email.trim())
}
