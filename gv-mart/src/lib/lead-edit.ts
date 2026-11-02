/**
 * Pure logic for the Edit Lead screen (#3, 2026-11-02), kept out of the
 * dialog component so it can be unit tested without mounting React or
 * mocking supabase (no vi.mock("@/lib/supabase") pattern exists elsewhere
 * in this codebase to follow, so pure functions are the testable surface).
 */

export type DuplicateCandidate = {
  id: string
  name: string
  /** "lead" or "customer" -- which table this candidate came from. */
  kind: "lead" | "customer"
}

/**
 * Builds the WARN (never block) message data for "another lead/customer
 * already has this number" — the caller runs the two read queries (leads
 * and customers, both already readable by staff under existing RLS) and
 * passes every row whose normalized mobile OR alternate_mobile matched,
 * excluding the lead being edited itself.
 */
export function findDuplicateMobileMatches(candidates: DuplicateCandidate[], excludeLeadId: string | null | undefined): DuplicateCandidate[] {
  if (candidates.length === 0) return []
  return candidates.filter((c) => !(c.kind === "lead" && excludeLeadId && c.id === excludeLeadId))
}

/**
 * CRITICAL referral-safety guard (owner_id is simply never a parameter of
 * the edit RPC, so it can't be touched from this screen at all -- see
 * EditLeadDialog.tsx). `source` IS editable, but only among non-referral
 * values: a lead's source can never be flipped TO 'referral' (that
 * attribution is only ever set by the referral-capture flow --
 * _dedupe_referral_leads / technician_finder_conversions key off
 * source='referral' + owner_id, see
 * 20261117100002_referral_finder_credit_dedupe.sql) nor FROM 'referral'
 * (that would silently erase a technician's already-earned finder credit
 * basis). Mirrors the DB-side check in update_lead_details so the UI can
 * reject the same way before ever making the round trip.
 */
export function isLeadSourceEditAllowed(currentSource: string, nextSource: string): boolean {
  if (currentSource === nextSource) return true
  if (currentSource === "referral" || nextSource === "referral") return false
  return true
}

export type LeadEditableSnapshot = {
  name: string
  mobile: string | null
  alternate_mobile: string | null
  address_text: string | null
  source: string
  product_type_key: string | null
  notes: string | null
}

/**
 * Diff builder mirroring what the DB audit trigger (audit_lead_edit_fields,
 * see the migration) writes into audit_log.before/after -- only the fields
 * this screen can actually change, and only when at least one of them did.
 * Returns null when nothing changed (no-op save), matching the DB trigger's
 * own early-return guard (same pattern as audit_profile_changes).
 */
export function buildLeadEditAuditDiff(before: LeadEditableSnapshot, after: LeadEditableSnapshot): { before: LeadEditableSnapshot; after: LeadEditableSnapshot } | null {
  const keys: (keyof LeadEditableSnapshot)[] = ["name", "mobile", "alternate_mobile", "address_text", "source", "product_type_key", "notes"]
  const changed = keys.some((k) => before[k] !== after[k])
  if (!changed) return null
  return { before, after }
}
