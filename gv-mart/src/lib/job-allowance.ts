// GV.md §1.1/§1.2: "the technician sees the estimated time for that service,
// from the admin-set item times. Admin also sets a review time and a
// new-enquiry time allowance. If review time = 5 min, then estimated time +
// 5 min is shown as the technician's total allowed time (same logic for the
// enquiry allowance)."
//
// This is the INPUT computation the already-built overrun mechanism
// (src/lib/job-overrun.ts#computeJobOverrun) consumes — job-overrun.ts
// itself is deliberately left untouched (per Build Order A4, already built
// and out of scope to rebuild); every call site now computes an
// `allowedDurationMinutes` here first and passes THAT in as
// `estimatedDurationMinutes` to computeJobOverrun, instead of the ticket's
// raw `estimated_duration_minutes`. Kept as a sibling pure module (not
// folded into job-overrun.ts) so the single-purpose "compare elapsed vs a
// number" function stays exactly that.
//
// Design decisions (see the build report for the full rationale):
//  - BASE estimate: sum of the job's actual inventory items' admin-set
//    `standard_time_minutes` (GV.md 1.1/D4 — the same items that populate
//    the SOP checklist), falling back to the ticket's existing
//    type-derived `estimated_duration_minutes` (the Phase 1 trigger's
//    default, or an admin manual override — both live in that one column)
//    whenever no item carries a standard time yet (e.g. right at ticket
//    creation, before any items are selected). Once items with standard
//    times exist, the item-sum takes priority over the type default/manual
//    override — GV.md's own wording ("from the admin-set item times") reads
//    as item-driven estimate superseding the coarser type default once it's
//    knowable, which is the call made here.
//  - Allowances are CONDITIONAL, never flat additions — see
//    `reviewCollected`/`enquiryLoggedThisVisit` below.
export interface AllowedDurationInput {
  /** Sum of (qty × spares.standard_time_minutes) for every item actually used on this job, from items with a standard time set. 0 when no items are known yet or none have a time set. */
  itemsStandardMinutesSum: number
  /** service_tickets.estimated_duration_minutes — the type-based default (Phase 1 trigger) or an admin manual override. Used only when itemsStandardMinutesSum is 0. */
  ticketEstimatedDurationMinutes: number | null | undefined
  /** settings.review_time_allowance_minutes */
  reviewAllowanceMinutes: number
  /** settings.enquiry_time_allowance_minutes */
  enquiryAllowanceMinutes: number
  /**
   * True only when THIS visit's rating row has google_review_clicked = true.
   * Note: a rating can only exist once the visit's timer has already been
   * closed (RatingPage runs after handlePaymentSubmit ends the visit), so
   * for a still-OPEN visit this is always false — the review allowance only
   * ever shows up once a visit is no longer live/overrunnable. That's the
   * literal reading of GV.md 1.2 ("actually collected a review"), not a
   * bug — see the build report for the timing note.
   */
  reviewCollected: boolean
  /** True when a lead (leads.visit_id) was generated during this specific visit — knowable live, since "Generate Enquiry" is available throughout the on-site flow before the visit closes. */
  enquiryLoggedThisVisit: boolean
}

/**
 * Sums standard_time_minutes × qty across a job's used items, skipping any
 * item that has no standard time set yet (rather than treating it as 0 and
 * silently shrinking the estimate — see 20260725100000_sop_item_times_and_
 * allowances.sql's column comment: null means "not yet timed").
 */
export function sumItemStandardMinutes(items: { qty: number; standardTimeMinutes: number | null | undefined }[]): number {
  return items.reduce((sum, item) => (item.standardTimeMinutes && item.standardTimeMinutes > 0 ? sum + item.standardTimeMinutes * item.qty : sum), 0)
}

/**
 * Returns null exactly when computeJobOverrun would also treat the result as
 * "nothing to compare against" (no base estimate available at all) — same
 * never-invent-a-comparison contract as job-overrun.ts.
 */
export function computeAllowedDurationMinutes(input: AllowedDurationInput): number | null {
  const base = input.itemsStandardMinutesSum > 0 ? input.itemsStandardMinutesSum : (input.ticketEstimatedDurationMinutes ?? null)
  if (base == null || base <= 0) return null

  let allowed = base
  if (input.reviewCollected) allowed += input.reviewAllowanceMinutes
  if (input.enquiryLoggedThisVisit) allowed += input.enquiryAllowanceMinutes
  return allowed
}
