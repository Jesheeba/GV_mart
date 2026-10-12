import { describe, expect, it, vi } from "vitest"
import { createClient } from "@supabase/supabase-js"

/**
 * KPI step 1 — LIVE check against a throwaway `__TEST_` organisation. Skipped unless KPI_LIVE=1.
 * A driver outside the repo seeds the org (one normal customer, one is_test customer, leads/tickets/AMC for each), creates a
 * master user in it, runs this file, then purges everything. It never runs in the normal suite and never touches the real org.
 * Env: KPI_LIVE, KPI_LIVE_URL, KPI_LIVE_ANON, KPI_LIVE_EMAIL, KPI_LIVE_PASSWORD, KPI_LIVE_ORG.
 */
const live = process.env.KPI_LIVE === "1"
const client = live ? createClient(process.env.KPI_LIVE_URL!, process.env.KPI_LIVE_ANON!, { auth: { persistSession: false } }) : null

vi.mock("@/lib/supabase", () => ({ get supabase() { return client } }))

import { listTickets } from "@/services/service"
import { listLeads } from "@/services/automation"
import { listAmcContracts } from "@/services/amc"

const names = (rows: { name?: string | null }[]) => rows.map((r) => r.name).sort()

describe.skipIf(!live)("test-customer exclusion, live in a __TEST_ org", () => {
  const org = process.env.KPI_LIVE_ORG!

  it("signs in as the throwaway master", async () => {
    const { error } = await client!.auth.signInWithPassword({ email: process.env.KPI_LIVE_EMAIL!, password: process.env.KPI_LIVE_PASSWORD! })
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
})
