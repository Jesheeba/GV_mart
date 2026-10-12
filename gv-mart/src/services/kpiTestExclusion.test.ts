import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * KPI step 1: dashboards must never count rows that belong to an `is_test` customer / lead.
 * The exclusion is opt-in (`excludeTest`) so the list pages keep showing everything. These tests pin the query each
 * service builds; the live behaviour against real PostgREST is covered by the throwaway-org check in the PR notes.
 */
type Call = { method: string; args: unknown[] }
const state: { table: string; calls: Call[]; data: unknown[] } = { table: "", calls: [], data: [] }

function builder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: state.data, error: null })
      }
      return (...args: unknown[]) => {
        state.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: (table: string) => {
      state.table = table
      state.calls = []
      return builder()
    },
  },
}))

import { listTickets, listTicketsMissingProduct } from "@/services/service"
import { listLeads } from "@/services/automation"
import { listAmcContracts } from "@/services/amc"
import { listQuotations } from "@/services/quotations"

const selectArg = () => String(state.calls.find((c) => c.method === "select")?.args[0] ?? "")
const eqCalls = () => state.calls.filter((c) => c.method === "eq").map((c) => [c.args[0], c.args[1]])

beforeEach(() => {
  state.calls = []
  state.data = []
})

describe("listTickets excludeTest", () => {
  it("inner-joins the customer and drops is_test customers when asked", async () => {
    await listTickets("org-1", { excludeTest: true })
    expect(state.table).toBe("service_tickets")
    expect(selectArg()).toContain("customers!inner(name, mobile)")
    expect(eqCalls()).toContainEqual(["customers.is_test", false])
  })
  it("leaves the default query untouched (list pages keep every ticket)", async () => {
    await listTickets("org-1", {})
    expect(selectArg()).toContain("customers(name, mobile)")
    expect(selectArg()).not.toContain("!inner")
    expect(eqCalls().some(([c]) => c === "customers.is_test")).toBe(false)
  })
})

describe("listLeads excludeTest", () => {
  it("filters leads.is_test = false when asked (customer-flagged and mobile-matched leads are both flagged by the DB trigger)", async () => {
    await listLeads("org-1", { excludeTest: true, dateRange: { from: "2026-10-01", to: "2026-10-31" } })
    expect(state.table).toBe("leads")
    expect(eqCalls()).toContainEqual(["is_test", false])
  })
  it("does not filter by default", async () => {
    await listLeads("org-1", {})
    expect(eqCalls().some(([c]) => c === "is_test")).toBe(false)
  })
})

describe("listAmcContracts excludeTest", () => {
  it("inner-joins the customer and drops is_test customers when asked", async () => {
    await listAmcContracts("org-1", { excludeTest: true })
    expect(state.table).toBe("amc_contracts")
    expect(selectArg()).toContain("customers!inner(name, mobile)")
    expect(eqCalls()).toContainEqual(["customers.is_test", false])
  })
  it("default call is unchanged", async () => {
    await listAmcContracts("org-1")
    expect(selectArg()).toContain("customers(name, mobile)")
    expect(eqCalls().some(([c]) => c === "customers.is_test")).toBe(false)
  })
})

describe("listQuotations excludeTest", () => {
  it("selects is_test on both embeds so a flagged customer or flagged lead can be recognised", async () => {
    await listQuotations("org-1", undefined, { excludeTest: true })
    expect(state.table).toBe("quotations")
    expect(selectArg()).toContain("customers(name,mobile,is_test)")
    expect(selectArg()).toContain("leads(name,is_test)")
  })
  const row = (id: string, customer: boolean | null, lead: boolean | null) => ({
    id,
    status: "converted",
    customers: customer === null ? null : { name: "c", mobile: "m", is_test: customer },
    leads: lead === null ? null : { name: "l", is_test: lead },
  })
  it("drops a flagged customer's and a flagged lead's quotations, keeps normal ones", async () => {
    state.data = [row("normal-customer", false, null), row("flagged-customer", true, null), row("flagged-lead-only", null, true), row("normal-lead", null, false), row("both-normal", false, false), row("customer-ok-lead-flagged", false, true)]
    const kept = await listQuotations("org-1", undefined, { excludeTest: true })
    expect(kept.map((q) => q.id)).toEqual(["normal-customer", "normal-lead", "both-normal"])
  })
  it("returns everything when excludeTest is off", async () => {
    state.data = [row("a", true, null), row("b", false, null)]
    expect((await listQuotations("org-1")).length).toBe(2)
  })
})

describe("listTicketsMissingProduct excludeTest", () => {
  it("inner-joins the customer and drops is_test customers when asked", async () => {
    await listTicketsMissingProduct("org-1", { excludeTest: true })
    expect(state.table).toBe("service_tickets")
    expect(selectArg()).toContain("customers!inner(name)")
    expect(eqCalls()).toContainEqual(["customers.is_test", false])
    // the existing "no product yet" predicates are untouched
    expect(state.calls.some((c) => c.method === "is" && c.args[0] === "product_id")).toBe(true)
  })
  it("default call is unchanged", async () => {
    await listTicketsMissingProduct("org-1")
    expect(selectArg()).toContain("customers(name)")
    expect(selectArg()).not.toContain("!inner")
    expect(eqCalls().some(([c]) => c === "customers.is_test")).toBe(false)
  })
})
