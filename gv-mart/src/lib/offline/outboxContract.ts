import type { OutboxKind } from "./db"

/**
 * Tag written into every NEW outbox payload (see outbox.ts's `enqueue`).
 * Bump this only when you need to tell payloads apart for a genuine
 * behavior change in the replayer — NOT on every release. A job already
 * sitting in a technician's IndexedDB when an OTA update lands keeps
 * whatever `__v` (or none at all, for jobs queued before this field
 * existed) it was created with; `runJob` in sync.ts never branches on it.
 * It exists purely so a `lastError` on a stuck job can show which app
 * version wrote the payload, for triage.
 */
export const OUTBOX_PAYLOAD_VERSION = 1

/**
 * Ground truth of the fields each job kind's payload has always carried,
 * extracted directly from the `enqueue(...)` call sites in services/technician.ts.
 *
 * ADDITIVE-ONLY, FOREVER: once a kind ships, only ADD new field names here
 * (and to the object literal at its enqueue call site) — never remove or
 * rename one. A job queued offline today may not sync until days later, on
 * a different OTA bundle; `runJob` (sync.ts) must still know how to read
 * every field it was ever built with. See docs/OFFLINE_OUTBOX_COMPATIBILITY.md.
 *
 * `outboxContract.test.ts` pins this object to a golden snapshot — if a
 * future change drops a field from one of these arrays, that test fails.
 */
export const OUTBOX_REQUIRED_FIELDS: Record<OutboxKind, readonly string[]> = {
  "attendance.mark": ["org_id", "technician_id", "date", "check_in_at", "inside_geofence", "selfie_url", "is_late", "affirmation", "pledge", "meeting"],
  "attendance.lunch": ["technicianId", "date", "patch"],
  "attendance.checkout": ["technicianId", "date", "checkOutAt"],
  "spare_handover.confirm": ["handoverId", "techSignUrl", "adminSignUrl"],
  "spare_handover.report_discrepancy": ["orgId", "itemId", "receivedQty"],
  "service_visit.start": ["id", "org_id", "ticket_id", "technician_id", "timer_start"],
  "service_visit.image": ["visitId", "column", "url"],
  "service_visit.arrive": ["visitId", "patch"],
  "sop_step.complete": ["id", "org_id", "visit_id", "step_name", "expected_minutes", "done_at", "overdue_minutes"],
  "ro_checklist.save": [
    "org_id",
    "visit_id",
    "tds_before",
    "tds_after",
    "tank_cleaned",
    "product_explained",
    "client_name",
    "water_tds_ppm",
    "water_ph",
    "water_hardness_ppm",
    "water_source",
    "water_source_other",
    "water_extra_readings",
  ],
  "service_invoice.create": [
    "orgId",
    "visitId",
    "serviceCharge",
    "discountPercent",
    "spares",
    "paymentMethod",
    "txnId",
    "paymentDescription",
    "isChargeable",
    "amountPaid",
    "installations",
  ],
  "rating.submit": ["orgId", "visitId", "stars", "review", "lowRatingReason"],
  "lead.generate": ["orgId", "customerId", "name", "mobile", "enquiryType", "note", "visitId"],
  "location.ping": ["org_id", "technician_id", "lat", "lng", "recorded_at"],
  "amc.sell_onsite": ["orgId", "customerId", "productId", "planId", "paymentMethod", "txnId", "paymentDescription"],
  "location.arrival_address_confirm": ["orgId", "ticketId", "lat", "lng"],
  "location.arrival_block": ["org_id", "technician_id", "ticket_id", "lat", "lng", "distance_m", "radius_m"],
  "customer_member.google_review": ["orgId", "visitId", "memberId", "stars", "photoUrl"],
  "rating.mark_review_clicked": ["orgId", "visitId"],
}

/**
 * Throws if `payload` is missing a field this kind has always required —
 * catches a genuinely broken enqueue call site (a real bug) without ever
 * rejecting an older job for merely lacking a field added *after* it was
 * queued, since that field (by the additive-only rule) was never in this
 * list to begin with. Called once at the top of `runJob` for every kind.
 */
export function assertRequiredFields(kind: OutboxKind, payload: Record<string, unknown>): void {
  const required = OUTBOX_REQUIRED_FIELDS[kind]
  const missing = required.filter((field) => !(field in payload))
  if (missing.length > 0) {
    throw new Error(`outbox job "${kind}" payload is missing required field(s): ${missing.join(", ")}`)
  }
}
