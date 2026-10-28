import { describe, expect, it } from "vitest"
import { buildStockLog, type SpareHandoverListItem, type SpareReturnListItem } from "./techniciansAdmin"

// Requirement 2 (2026-11-14 gap fix) — "who gave it" + dispute flagging must survive into
// the merged chronological log the admin Stock tab renders.
function makeHandover(overrides: Partial<SpareHandoverListItem> = {}): SpareHandoverListItem {
  return {
    id: "h1",
    org_id: "org1",
    technician_id: "t1",
    date: "2026-11-10",
    admin_sign_url: null,
    tech_sign_url: null,
    status: "pending",
    given_by: "staff1",
    created_at: "2026-11-10T00:00:00Z",
    updated_at: "2026-11-10T00:00:00Z",
    technicians: { id: "t1", profiles: { full_name: "Ravi" } },
    given_by_profile: { full_name: "Admin Priya" },
    spare_handover_items: [
      {
        id: "i1",
        org_id: "org1",
        handover_id: "h1",
        spare_id: "s1",
        qty_given: 5,
        qty_returned: 0,
        received_qty: null,
        dispute_note: null,
        created_at: "2026-11-10T00:00:00Z",
        updated_at: "2026-11-10T00:00:00Z",
        spares: { name: "RO Filter", sku: "RF-1" },
      },
    ],
    ...overrides,
  }
}

function makeReturn(overrides: Partial<SpareReturnListItem> = {}): SpareReturnListItem {
  return {
    id: "r1",
    org_id: "org1",
    technician_id: "t1",
    date: "2026-11-09",
    created_at: "2026-11-09T00:00:00Z",
    updated_at: "2026-11-09T00:00:00Z",
    technicians: { id: "t1", profiles: { full_name: "Ravi" } },
    spare_return_items: [
      { id: "ri1", org_id: "org1", return_id: "r1", spare_id: "s1", qty_returned: 2, created_at: "2026-11-09T00:00:00Z", spares: { name: "RO Filter", sku: "RF-1" } },
    ],
    ...overrides,
  }
}

describe("buildStockLog", () => {
  it("carries given_by_profile into givenByName for a hand-over entry", () => {
    const log = buildStockLog([makeHandover()], [])
    expect(log[0]).toMatchObject({ kind: "handover", givenByName: "Admin Priya", disputed: false })
  })

  it("falls back to null givenByName when given_by_profile is missing (pre-2026-11-14 rows)", () => {
    const log = buildStockLog([makeHandover({ given_by_profile: null })], [])
    expect(log[0]?.givenByName).toBeNull()
  })

  it("flags disputed = true when any item has a non-null received_qty", () => {
    const handover = makeHandover({
      spare_handover_items: [
        { id: "i1", org_id: "org1", handover_id: "h1", spare_id: "s1", qty_given: 5, qty_returned: 0, received_qty: 3, dispute_note: "short by 2", created_at: "", updated_at: "", spares: { name: "RO Filter", sku: "RF-1" } },
      ],
    })
    const log = buildStockLog([handover], [])
    expect(log[0]?.disputed).toBe(true)
  })

  it("does not flag disputed when received_qty is null on every item", () => {
    const log = buildStockLog([makeHandover()], [])
    expect(log[0]?.disputed).toBe(false)
  })

  it("a return entry always has givenByName null and disputed false", () => {
    const log = buildStockLog([], [makeReturn()])
    expect(log[0]).toMatchObject({ kind: "return", givenByName: null, disputed: false })
  })

  it("sorts newest-first across handovers and returns combined", () => {
    const log = buildStockLog([makeHandover({ date: "2026-11-10" })], [makeReturn({ date: "2026-11-09" })])
    expect(log.map((l) => l.kind)).toEqual(["handover", "return"])
  })
})
