import { describe, expect, it } from "vitest"
import { assertRequiredFields, OUTBOX_REQUIRED_FIELDS } from "./outboxContract"
import type { OutboxKind } from "./db"

// Pinned snapshot of every kind's required-field set as of 2026-10-29.
// ADDITIVE-ONLY: a future PR may only ADD fields to an existing kind's
// array (update this snapshot to match), or add a brand-new kind. If this
// test fails because a kind's array in outboxContract.ts has FEWER fields
// than listed here, that is exactly the regression this test exists to
// catch — a field silently dropped from a payload shape a technician's
// already-queued, not-yet-synced job may still be relying on.
const GOLDEN_SNAPSHOT: Record<OutboxKind, readonly string[]> = {
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
  // Product Lifecycle & Automated Service Reminder System (2026-10-29) — see
  // outboxContract.lifecycle.test.ts for this kind's own dedicated contract
  // test; it's also listed here so "no kind is missing from the registry"
  // below keeps covering it like every other kind.
  "product_lifecycle.mark_replaced": ["scheduleId", "replacedDate", "spareUsedId", "visitId"],
}

function payloadFromFields(fields: readonly string[]): Record<string, unknown> {
  const payload: Record<string, unknown> = {}
  for (const f of fields) payload[f] = "x"
  return payload
}

describe("OUTBOX_REQUIRED_FIELDS additive-only guarantee", () => {
  it("every kind's current field set is a superset of the golden snapshot", () => {
    for (const kind of Object.keys(GOLDEN_SNAPSHOT) as OutboxKind[]) {
      const current = new Set(OUTBOX_REQUIRED_FIELDS[kind])
      const missing = GOLDEN_SNAPSHOT[kind].filter((field) => !current.has(field))
      expect.soft(missing, `outboxContract.ts["${kind}"] dropped field(s): ${missing.join(", ")}`).toEqual([])
    }
  })

  it("no kind is missing from the registry", () => {
    expect(Object.keys(OUTBOX_REQUIRED_FIELDS).sort()).toEqual(Object.keys(GOLDEN_SNAPSHOT).sort())
  })
})

describe("assertRequiredFields", () => {
  it("accepts a payload with exactly the required fields, for every kind", () => {
    for (const kind of Object.keys(OUTBOX_REQUIRED_FIELDS) as OutboxKind[]) {
      const payload = payloadFromFields(OUTBOX_REQUIRED_FIELDS[kind])
      expect(() => assertRequiredFields(kind, payload)).not.toThrow()
    }
  })

  it("accepts a payload with extra fields a later app version added", () => {
    const payload = payloadFromFields(OUTBOX_REQUIRED_FIELDS["rating.submit"])
    payload.someFieldAddedLater = "new"
    expect(() => assertRequiredFields("rating.submit", payload)).not.toThrow()
  })

  it("accepts a legacy payload that predates the __v/payloadVersion tag entirely", () => {
    // Simulates a job queued before this change shipped — no payloadVersion
    // on the OutboxJob row at all (see outbox.ts). assertRequiredFields only
    // looks at payload fields, so this must behave identically either way.
    const payload = payloadFromFields(OUTBOX_REQUIRED_FIELDS["attendance.mark"])
    expect(() => assertRequiredFields("attendance.mark", payload)).not.toThrow()
  })

  it("rejects a payload missing a required field — the regression this whole mechanism exists to catch", () => {
    const required = OUTBOX_REQUIRED_FIELDS["service_invoice.create"]
    const payload = payloadFromFields(required.slice(1)) // drop the first required field
    expect(() => assertRequiredFields("service_invoice.create", payload)).toThrow(/missing required field/)
  })
})
