import { describe, expect, it } from "vitest"
import { resolveEventContext } from "./wa-event-context.ts"
import type { PendingRow } from "./wa-dispatch-v2.ts"

// resolveEventContext reads Deno.env directly (WA_PUBLIC_APP_URL) — every other test file in this
// project mocks wa-event-context.ts away entirely rather than executing it under vitest/Node. This
// is the first to exercise it directly, so it needs the one Deno global the function touches.
;(globalThis as Record<string, unknown>).Deno ??= { env: { get: () => undefined } }

// Generic fake admin: "byId" tables resolve a single row by its `id` filter; "byParent" tables
// (quotation_items/invoice_items) resolve the first row (by insertion order) matching whichever
// non-id .eq() filter was applied, mirroring the real .order("created_at").limit(1) usage in
// wa-event-context.ts. No network, no Deno import — pure in-memory fixtures per test.
function fakeAdmin(byId: Record<string, Record<string, Record<string, unknown>>>, byParent: Record<string, Record<string, Record<string, unknown>>[]> = {}) {
  const from = (table: string) => {
    const filters: Record<string, unknown> = {}
    const b: Record<string, unknown> = {}
    b.select = () => b
    b.eq = (col: string, v: unknown) => {
      filters[col] = v
      return b
    }
    b.order = () => b
    b.limit = () => b
    b.abortSignal = () => b
    b.maybeSingle = async () => {
      const id = filters.id as string | undefined
      const row = id ? byId[table]?.[id] : undefined
      return { data: row ?? null, error: null }
    }
    // invoice_items/quotation_items: awaited directly (no maybeSingle), filtered by parent fk column
    b.then = (resolve: (v: { data: unknown; error: null }) => unknown) => {
      const parentCol = Object.keys(filters).find((k) => k !== "id")
      const parentId = parentCol ? filters[parentCol] : undefined
      const rows = (byParent[table] ?? []).filter((r) => !parentCol || r[parentCol] === parentId)
      return resolve({ data: rows, error: null })
    }
    return b
  }
  return { from } as never
}

const baseRow = (overrides: Partial<PendingRow>): PendingRow =>
  ({
    id: "outbox-1",
    org_id: "org-1",
    customer_id: null,
    to_mobile: "9000000001",
    template: "milestone.x",
    payload: {},
    ref_type: null,
    ref_id: null,
    ...overrides,
  } as PendingRow)

describe("resolveEventContext — new ref_type branches (Phase B)", () => {
  it("lead: resolves customer_name/product_name/enquiry_number from the lead row itself, even with no customer_id", async () => {
    const admin = fakeAdmin({
      leads: { "lead-1": { name: "Ramesh", product_id: "prod-1" } },
      products: { "prod-1": { name: "Amaron Battery" } },
    })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "lead", ref_id: "lead-1", customer_id: null }))
    expect(ctx.vars.customer_name).toBe("Ramesh")
    expect(ctx.vars.product_name).toBe("Amaron Battery")
    expect(typeof ctx.vars.enquiry_number).toBe("string")
    expect(ctx.vars.enquiry_number).not.toBe("")
  })

  it("lead: missing product_id leaves product_name unresolved (null), not crashing", async () => {
    const admin = fakeAdmin({ leads: { "lead-2": { name: "Priya", product_id: null } } })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "lead", ref_id: "lead-2" }))
    expect(ctx.vars.customer_name).toBe("Priya")
    expect(ctx.vars.product_name).toBeUndefined()
  })

  it("quotation: resolves quotation_number, amount, and first line item's product name", async () => {
    const admin = fakeAdmin(
      { quotations: { "quote-1": { id: "quote-1", total: 4500 } }, products: { "prod-9": { name: "RO Purifier AXB" } } },
      { quotation_items: [{ quotation_id: "quote-1", item_type: "product", item_id: "prod-9", created_at: "2026-01-01" }] }
    )
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "quotation", ref_id: "quote-1" }))
    expect(ctx.vars.amount).toBe("Rs 4,500")
    expect(ctx.vars.product_name).toBe("RO Purifier AXB")
    expect(ctx.vars.quotation_number).toBeTruthy()
  })

  it("amc_contract: resolves amc_number and formatted expiry_date", async () => {
    const admin = fakeAdmin({ amc_contracts: { "amc-1": { id: "amc-1", expiry_date: "2027-03-15T00:00:00Z" } } })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "amc_contract", ref_id: "amc-1", customer_id: "cust-1" }))
    expect(ctx.vars.amc_number).toBeTruthy()
    expect(ctx.vars.expiry_date).toBe("15 Mar 2027")
  })

  it("payment: resolves amount and complaint_number from the ticket_id carried in payload", async () => {
    const admin = fakeAdmin({ payments: { "pay-1": { id: "pay-1", amount: 1200 } } })
    const ctx = await resolveEventContext(
      admin,
      baseRow({ ref_type: "payment", ref_id: "pay-1", customer_id: "cust-1", payload: { ticket_id: "ticket-abc123" } })
    )
    expect(ctx.vars.amount).toBe("Rs 1,200")
    expect(ctx.vars.complaint_number).toBeTruthy()
  })

  it("payment: a missing ticket_id in payload resolves complaint_number to an empty string, not a crash", async () => {
    const admin = fakeAdmin({ payments: { "pay-2": { id: "pay-2", amount: 500 } } })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "payment", ref_id: "pay-2", payload: {} }))
    expect(ctx.vars.amount).toBe("Rs 500")
    expect(ctx.vars.complaint_number).toBe("")
  })

  it("an unresolvable ref (row deleted since) leaves vars empty instead of throwing", async () => {
    const admin = fakeAdmin({ leads: {} })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "lead", ref_id: "gone" }))
    expect(ctx.vars.customer_name).toBeNull()
  })
})

describe("resolveEventContext — audience_segment_match (Segment Builder)", () => {
  it("standing fire: resolves product_name from the exact triggering invoice_item in payload", async () => {
    const admin = fakeAdmin({
      invoice_items: { "item-1": { item_type: "product", item_id: "prod-amaron" } },
      products: { "prod-amaron": { name: "Amaron Battery 150Ah" } },
    })
    const ctx = await resolveEventContext(
      admin,
      baseRow({ ref_type: "audience_segment_match", ref_id: "seg-1", customer_id: "cust-1", payload: { segment_id: "seg-1", invoice_item_id: "item-1" } })
    )
    expect(ctx.vars.product_name).toBe("Amaron Battery 150Ah")
  })

  it("manual send-now fire: no invoice_item_id in payload, falls back to the customer's most recent purchase", async () => {
    const admin = fakeAdmin(
      { products: { "prod-ro": { name: "RO Purifier X200" } } },
      {
        invoices: [{ id: "inv-1", customer_id: "cust-1", created_at: "2026-01-01" }],
        invoice_items: [{ invoice_id: "inv-1", item_type: "product", item_id: "prod-ro", created_at: "2026-01-01" }],
      }
    )
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "audience_segment_match", ref_id: "seg-2", customer_id: "cust-1", payload: {} }))
    expect(ctx.vars.product_name).toBe("RO Purifier X200")
  })

  it("no customer_id on the row leaves product_name unresolved rather than crashing", async () => {
    const admin = fakeAdmin({})
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "audience_segment_match", ref_id: "seg-3", customer_id: null, payload: {} }))
    expect(ctx.vars.product_name).toBeUndefined()
  })
})

describe("resolveEventContext — service_ticket product_name addition", () => {
  it("installation ticket: resolves product_name off the ticket's own product_id", async () => {
    const admin = fakeAdmin(
      {
        service_tickets: { "ticket-1": { id: "ticket-1", name_of_complaint: null, product_id: "prod-5", unlisted_product_name: null } },
        products: { "prod-5": { name: "5-Stage RO System" } },
        appointments: {},
      },
      {}
    )
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "service_ticket", ref_id: "ticket-1", customer_id: "cust-1" }))
    expect(ctx.vars.product_name).toBe("5-Stage RO System")
  })

  it("installation ticket: unlisted_product_name wins over a product_id lookup", async () => {
    const admin = fakeAdmin({
      service_tickets: { "ticket-2": { id: "ticket-2", name_of_complaint: null, product_id: "prod-5", unlisted_product_name: "Custom RO Unit" } },
      products: { "prod-5": { name: "5-Stage RO System" } },
      appointments: {},
    })
    const ctx = await resolveEventContext(admin, baseRow({ ref_type: "service_ticket", ref_id: "ticket-2", customer_id: "cust-1" }))
    expect(ctx.vars.product_name).toBe("Custom RO Unit")
  })
})
