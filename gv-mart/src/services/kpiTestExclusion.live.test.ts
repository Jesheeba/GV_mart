import { describe, expect, it, vi } from "vitest"
import { createClient } from "@supabase/supabase-js"

/**
 * KPI step 1 — LIVE check against a throwaway `__TEST_` organisation. Skipped unless KPI_LIVE=1.
 * A driver outside the repo seeds the org (one normal customer, one is_test customer, leads/tickets/AMC for each), creates a
 * master user in it, runs this file, then purges everything. It never runs in the normal suite and never touches the real org.
 * Env: KPI_LIVE, KPI_LIVE_URL, KPI_LIVE_ANON, KPI_LIVE_EMAIL, KPI_LIVE_PASSWORD, KPI_LIVE_ORG.
 */
// the app tsconfig has no node types; this file only ever runs under vitest (node)
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env
const live = env.KPI_LIVE === "1"
const client = live ? createClient(env.KPI_LIVE_URL!, env.KPI_LIVE_ANON!, { auth: { persistSession: false } }) : null

vi.mock("@/lib/supabase", () => ({ get supabase() { return client } }))

import { listTickets, listTicketsMissingProduct } from "@/services/service"
import { listLeads } from "@/services/automation"
import { listAmcContracts } from "@/services/amc"
import { listQuotations } from "@/services/quotations"

const names = (rows: { name?: string | null }[]) => rows.map((r) => r.name).sort()

describe.skipIf(!live)("test-customer exclusion, live in a __TEST_ org", () => {
  const org = env.KPI_LIVE_ORG!

  it("signs in as the throwaway master", async () => {
    const { error } = await client!.auth.signInWithPassword({ email: env.KPI_LIVE_EMAIL!, password: env.KPI_LIVE_PASSWORD! })
    expect(error).toBeNull()
  })

  it("leads: flagged customer's lead and the mobile-matched lead are dropped, normal leads still count", async () => {
    const all = await listLeads(org, {})
    const kept = await listLeads(org, { excludeTest: true })
    expect(names(all)).toEqual(["__TEST_ L flagged", "__TEST_ L matched-by-mobile", "__TEST_ L normal", "__TEST_ L normal 2", "__TEST_ L unrelated"])
    expect(names(kept)).toEqual(["__TEST_ L normal", "__TEST_ L normal 2", "__TEST_ L unrelated"])
    // the Owner "Lead Conversion" numbers: won / total
    expect(all.filter((l) => l.status === "won").length).toBe(3)
    expect(kept.filter((l) => l.status === "won").length).toBe(1)
  })

  it("leads: the period filter composes with excludeTest", async () => {
    const today = new Date().toISOString().slice(0, 10)
    const kept = await listLeads(org, { excludeTest: true, dateRange: { from: today, to: today } })
    expect(kept.length).toBe(3)
  })

  it("tickets: flagged customer's open ticket is dropped, normal ticket still counts", async () => {
    const all = await listTickets(org, {})
    const kept = await listTickets(org, { excludeTest: true })
    expect(all.map((t) => t.name_of_complaint).sort()).toEqual(["__TEST_ T flagged", "__TEST_ T normal"])
    expect(kept.map((t) => t.name_of_complaint)).toEqual(["__TEST_ T normal"])
    expect(kept.filter((t) => t.status !== "completed" && t.status !== "cancelled").length).toBe(1)
  })

  it("AMC: flagged customer's contract is dropped from Due Soon, normal contract still counts", async () => {
    const all = await listAmcContracts(org)
    const kept = await listAmcContracts(org, { excludeTest: true })
    expect(all.length).toBe(2)
    expect(all.filter((c) => c.status === "due_soon").length).toBe(2)
    expect(kept.length).toBe(1)
    expect(kept[0].customers?.name).toBe("__TEST_ Normal")
    expect(kept.filter((c) => c.status === "due_soon").length).toBe(1)
  })

  it("quotations: flagged customer's and flagged lead's quotations are dropped from Quotation→Sale, normal ones still count", async () => {
    const all = await listQuotations(org)
    const kept = await listQuotations(org, undefined, { excludeTest: true })
    expect(all.length).toBe(4)
    expect(all.filter((q) => q.status === "converted").length).toBe(3)
    expect(kept.length).toBe(2)
    expect(kept.filter((q) => q.status === "converted").length).toBe(1)
    expect(kept.every((q) => !q.customers?.is_test && !q.leads?.is_test)).toBe(true)
  })

  it("ops dashboard source: excludeTest ticket list has the one normal open ticket and no completed-today leak", async () => {
    const kept = await listTickets(org, { excludeTest: true })
    expect(kept.map((t) => t.customers?.name)).toEqual(["__TEST_ Normal"])
  })

  it("missing-product nag: a flagged customer's ticket without a product is dropped, the normal one still appears", async () => {
    const all = await listTicketsMissingProduct(org)
    const kept = await listTicketsMissingProduct(org, { excludeTest: true })
    expect(all.map((t) => t.name_of_complaint).sort()).toEqual(["__TEST_ T flagged", "__TEST_ T normal"])
    expect(kept.map((t) => t.name_of_complaint)).toEqual(["__TEST_ T normal"])
  })
})
