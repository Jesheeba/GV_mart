import { describe, expect, it } from "vitest"
import { assertRequiredFields, OUTBOX_REQUIRED_FIELDS } from "./outboxContract"

/**
 * Dedicated golden-snapshot test for "product_lifecycle.mark_replaced"
 * (Product Lifecycle & Automated Service Reminder System, 2026-10-29) —
 * mirrors outboxContract.test.ts's pattern, scoped to just this brand-new
 * kind so this file can ship without touching the shared golden snapshot's
 * full enumeration test.
 *
 * ADDITIVE-ONLY, FOREVER (see outboxContract.ts's header comment): a future
 * change may only ADD field names to this kind's required-fields array —
 * never remove or rename one. If this test fails because
 * OUTBOX_REQUIRED_FIELDS["product_lifecycle.mark_replaced"] has FEWER
 * fields than listed here, that's exactly the regression this test exists
 * to catch.
 */
const KIND = "product_lifecycle.mark_replaced" as const

const GOLDEN_SNAPSHOT: readonly string[] = ["scheduleId", "replacedDate", "spareUsedId", "visitId"]

function payloadFromFields(fields: readonly string[]): Record<string, unknown> {
  const payload: Record<string, unknown> = {}
  for (const f of fields) payload[f] = "x"
  return payload
}

describe(`OUTBOX_REQUIRED_FIELDS["${KIND}"] additive-only guarantee`, () => {
  it("current field set is a superset of the golden snapshot", () => {
    const current = new Set(OUTBOX_REQUIRED_FIELDS[KIND])
    const missing = GOLDEN_SNAPSHOT.filter((field) => !current.has(field))
    expect(missing, `outboxContract.ts["${KIND}"] dropped field(s): ${missing.join(", ")}`).toEqual([])
  })
})

describe("assertRequiredFields for product_lifecycle.mark_replaced", () => {
  it("accepts a payload with exactly the required fields", () => {
    const payload = payloadFromFields(OUTBOX_REQUIRED_FIELDS[KIND])
    expect(() => assertRequiredFields(KIND, payload)).not.toThrow()
  })

  // spareUsedId/visitId are nullable at enqueue time (no spare named, or not
  // tied to a specific visit) — the field must still be PRESENT as a key, just
  // with a null value. assertRequiredFields only checks key presence (`field
  // in payload`), so a present-but-null field must pass, same as every other
  // kind's optional fields (see e.g. ro_checklist.save's tds_before/tds_after).
  it("accepts spareUsedId/visitId present but null", () => {
    const payload = { scheduleId: "sched-1", replacedDate: "2026-10-29", spareUsedId: null, visitId: null }
    expect(() => assertRequiredFields(KIND, payload)).not.toThrow()
  })

  it("accepts a payload with extra fields a later app version added", () => {
    const payload = payloadFromFields(OUTBOX_REQUIRED_FIELDS[KIND])
    payload.someFieldAddedLater = "new"
    expect(() => assertRequiredFields(KIND, payload)).not.toThrow()
  })

  it("rejects a payload missing a required field", () => {
    const required = OUTBOX_REQUIRED_FIELDS[KIND]
    const payload = payloadFromFields(required.slice(1)) // drop scheduleId
    expect(() => assertRequiredFields(KIND, payload)).toThrow(/missing required field/)
  })
})
