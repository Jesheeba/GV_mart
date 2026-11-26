import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * no-gst-bill (build-docs/features/no-gst-bill.md; migration 20270101100000). Same numbers as
 * supabase/tests/no_gst_bill.test.sql, so the screen total and the server invoice agree.
 */
const rpcCalls: { name: string; args: Record<string, unknown> }[] = []
const queued: { kind: string; payload: Record<string, unknown> }[] = []

vi.mock("react-i18next", () => ({ useTranslation: () => ({ t: (k: string) => k }) }))
vi.mock("@/lib/supabase", () => ({
  supabase: {
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcCalls.push({ name, args })
      return Promise.resolve({ data: name === "create_quotation" ? "q-1" : { contract_id: "c", invoice_id: "i" }, error: null })
    },
  },
}))
vi.mock("@/lib/offline/outbox", () => ({
  enqueue: (kind: string, payload: Record<string, unknown>) => {
    queued.push({ kind, payload })
    return Promise.resolve()
  },
}))

import { billBreakdown, defaultGstMode, gstModeParts, toGstMode } from "./sale-calc"
import { OUTBOX_REQUIRED_FIELDS } from "./offline/outboxContract"
import { GstModeToggle } from "@/components/shared/GstModeToggle"
import { GstSummary } from "@/components/shared/GstSummary"
import { createSale } from "@/services/sales"
import { createQuotation } from "@/services/quotations"
import { sellAmcPlan } from "@/services/amc"
import { createRental } from "@/services/rentals"
import { queueCreateServiceInvoice, queueSellAmcOnsite } from "@/services/technician"

beforeEach(() => {
  rpcCalls.length = 0
  queued.length = 0
})

const previewNoGst = (net: number, discount = 0) => {
  const p = gstModeParts("none", 18)
  return billBreakdown(net, discount, p.rate, p.gstInclusive)
}

describe("AC1 No GST totals match the server (GST 0, total = amount after discount)", () => {
  it("spare 12500 -> GST 0, total 12500", () => {
    expect(previewNoGst(12500)).toEqual({ subtotal: 12500, discount: 0, gst: 0, total: 12500 })
  })
  it("10% discount: 12500 -> discount 1250, GST 0, total 11250", () => {
    expect(previewNoGst(12500, 10)).toEqual({ subtotal: 12500, discount: 1250, gst: 0, total: 11250 })
  })
  it("AMC 2000 / service 1000 / rent 1000 -> GST 0, totals unchanged", () => {
    expect(previewNoGst(2000).total).toBe(2000)
    expect(previewNoGst(1000)).toMatchObject({ gst: 0, total: 1000 })
  })
  it("mode parts: none -> rate 0, noGst true, gstInclusive false", () => {
    expect(gstModeParts("none", 18)).toEqual({ gstInclusive: false, noGst: true, rate: 0 })
  })
})

describe("AC2 extra / included unchanged; No GST is never the default", () => {
  it("extra and included keep the org rate and the old totals", () => {
    expect(gstModeParts("extra", 18)).toEqual({ gstInclusive: false, noGst: false, rate: 18 })
    expect(gstModeParts("included", 18)).toEqual({ gstInclusive: true, noGst: false, rate: 18 })
    expect(billBreakdown(12500, 0, 18, false)).toMatchObject({ gst: 2250, total: 14750 })
  })
  it("the default comes from the org setting and is never none", () => {
    expect(defaultGstMode(false)).toBe("extra")
    expect(defaultGstMode(true)).toBe("included")
    expect(defaultGstMode(undefined)).toBe("extra")
  })
  it("drafts saved before this change (boolean) restore to the same mode; junk restores nothing", () => {
    expect(toGstMode(true)).toBe("included")
    expect(toGstMode(false)).toBe("extra")
    expect(toGstMode("none")).toBe("none")
    expect(toGstMode(null)).toBeNull()
    expect(toGstMode("zero")).toBeNull()
  })
})

describe("AC1 the switch offers three choices", () => {
  it("GstModeToggle renders extra, included and No GST with the chosen one checked", () => {
    const out = renderToStaticMarkup(createElement(GstModeToggle, { value: "none", onChange: () => {} }))
    expect(out.match(/role="radio"/g)).toHaveLength(3)
    expect(out).toContain("sales.gst.extra")
    expect(out).toContain("sales.gst.included")
    expect(out).toMatch(/aria-checked="true"[^>]*>sales\.gst\.none</)
  })
  it("GstSummary in No GST shows 'GST not charged' and the net as the total", () => {
    const out = renderToStaticMarkup(createElement(GstSummary, { net: 2000, rate: 18, mode: "none" }))
    expect(out).toContain("sales.gst.notCharged")
    expect(out).not.toContain("sales.summary.gst")
    expect(out).toContain("2,000.00")
    expect(out).not.toContain("2,360.00")
  })
})

describe("AC1/AC3/AC4 every staff billing path sends the choice", () => {
  it("New Sale: cart.no_gst true; absent -> false", async () => {
    const cart = { spareItems: [], productItems: [], amc: null, discountPercent: 0, giftId: null, paymentMethod: "cash" as const, txnId: null, paymentDescription: null, redeemPoints: 0, gstInclusive: false }
    await createSale("org", "cust", { ...cart, noGst: true })
    await createSale("org", "cust", cart)
    const carts = rpcCalls.map((c) => c.args.p_cart as Record<string, unknown>)
    expect(carts[0].no_gst).toBe(true)
    expect(carts[1].no_gst).toBe(false)
  })
  it("Quotation stores p_no_gst (AC4: carried into the sale)", async () => {
    await createQuotation("org", "cust", null, [], null, false, true)
    expect(rpcCalls[0]).toMatchObject({ name: "create_quotation", args: { p_no_gst: true } })
  })
  it("Admin Sell AMC sends p_no_gst; omitted -> null (server: GST charged)", async () => {
    const base = { orgId: "o", customerId: "c", productId: "p", planId: "pl", startDate: "2026-11-26" }
    await sellAmcPlan({ ...base, noGst: true })
    await sellAmcPlan(base)
    expect(rpcCalls[0].args.p_no_gst).toBe(true)
    expect(rpcCalls[1].args.p_no_gst).toBeNull()
  })
  it("Rent Out sends p_no_gst (AC3: stored on the contract for monthly bills)", async () => {
    await createRental({ orgId: "o", customerId: "c", productId: "p", planId: "pl", addressId: "a", startDate: "2026-11-26", paymentMethod: "cash", noGst: true })
    expect(rpcCalls[0]).toMatchObject({ name: "create_rental", args: { p_no_gst: true } })
  })
  it("Technician on-site invoice + AMC put noGst in the offline job", async () => {
    await queueCreateServiceInvoice({ orgId: "o", visitId: "v", serviceCharge: 1000, discountPercent: 0, spares: [], paymentMethod: "cash", isChargeable: true, noGst: true })
    await queueSellAmcOnsite({ orgId: "o", customerId: "c", productId: "p", planId: "pl", paymentMethod: "cash", noGst: true })
    expect(queued.map((q) => [q.kind, q.payload.noGst])).toEqual([
      ["service_invoice.create", true],
      ["amc.sell_onsite", true],
    ])
  })
  it("noGst is NOT a required outbox field (jobs queued before this change keep syncing)", () => {
    expect(OUTBOX_REQUIRED_FIELDS["service_invoice.create"]).not.toContain("noGst")
    expect(OUTBOX_REQUIRED_FIELDS["amc.sell_onsite"]).not.toContain("noGst")
  })
})
