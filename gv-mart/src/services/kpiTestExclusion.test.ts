import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * KPI step 1: dashboards must never count rows that belong to an `is_test` customer / lead.
 * The exclusion is opt-in (`excludeTest`) so the list pages keep showing everything. These tests pin the query each
 * service builds; the live behaviour against real PostgREST is covered by the throwaway-org check in the PR notes.
 */
type Call = { method: string; args: unknown[] }
const state: { table: string; calls: Call[] } = { table: "", calls: [] }

function builder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: [], error: null })
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

import { listTickets } from "@/services/service"
import { listLeads } from "@/services/automation"
import { listAmcContracts } from "@/services/amc"

const selectArg = () => String(state.calls.find((c) => c.method === "select")?.args[0] ?? "")
const eqCalls = () => state.calls.filter((c) => c.method === "eq").map((c) => [c.args[0], c.args[1]])

beforeEach(() => {
  state.calls = []
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
